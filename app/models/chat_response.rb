class ChatResponse < ApplicationRecord
  class Busy < StandardError; end

  attr_accessor :expected_attempt_token

  RUNNING_STATUSES = %w[searching writing].freeze
  ACTIVE_STATUSES = %w[queued searching writing cancelling].freeze
  FAILED_MESSAGE = "The assistant couldn't finish this reply. Your question is saved. Please try again.".freeze
  LOOKUP_FAILED_MESSAGE = "Local resources couldn't be looked up. Your question is saved. Please try again.".freeze

  belongs_to :chat
  belongs_to :user_message, class_name: "Message"
  belongs_to :assistant_message, class_name: "Message", optional: true

  enum :status, %w[queued searching writing cancelling completed failed cancelled].index_with(&:itself), validate: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  before_validation :assign_attempt_token, on: :create

  validates :model_id, :provider, :attempt_token, presence: true
  validates :user_message_id, uniqueness: true
  validate :messages_belong_to_conversation

  after_create_commit :dispatch
  after_update_commit :broadcast_status, if: :saved_change_to_status?

  def self.enqueue!(chat:, content:, model:, provider:)
    chat.with_lock do
      ChatResponseRecovery.call(chat)
      raise Busy, "The assistant is already replying to this conversation." if active.where(chat_id: chat.id).exists?

      user_message = chat.messages.create!(role: "user", content: content)
      create!(chat: chat, user_message: user_message, model_id: model, provider: provider.to_s)
    end
  end

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def retry!(expected_token: nil)
    chat.with_lock do
      with_lock do
        return :conflict if expected_token && expected_token != attempt_token
        return :conflict unless failed? && chat.chat_responses.maximum(:id) == id
        return :conflict if chat.chat_responses.active.exists?
        return :unavailable unless ChatModelAvailability.new.find(model_id, provider: provider)

        # A failed partial answer must not become history for its replacement.
        assistant_message&.destroy!
        self.assistant_message = nil
        update!(status: "queued", attempt_token: SecureRandom.uuid, error_message: nil, started_at: nil,
          finished_at: nil, heartbeat_at: Time.current)
        ActiveRecord.after_all_transactions_commit { enqueue_job }
        :queued
      end
    end
  end

  def claim!
    with_lock do
      return false unless current_attempt? && queued?

      update!(status: "searching", started_at: Time.current, heartbeat_at: Time.current)
      true
    end
  end

  def start_writing!
    with_lock do
      return false unless current_attempt? && searching?

      update!(status: "writing", heartbeat_at: Time.current)
      true
    end
  end

  def cancel!(expected_token: nil)
    with_lock do
      return false if expected_token && expected_token != attempt_token
      if queued?
        update!(status: "cancelled", error_message: nil, finished_at: Time.current, heartbeat_at: Time.current)
      elsif RUNNING_STATUSES.include?(status)
        # Keep the chat occupied until its worker has saved any partial reply.
        update!(status: "cancelling", error_message: nil, heartbeat_at: Time.current)
      end
      true
    end
  end

  def acknowledge_cancellation!
    with_lock do
      return false unless current_attempt? && cancelling?

      update!(status: "cancelled", error_message: nil, finished_at: Time.current, heartbeat_at: Time.current)
      true
    end
  end

  def cancellation_requested?
    self.class.uncached do
      query = self.class.where(id: id)
      query = query.where(attempt_token: expected_attempt_token) if expected_attempt_token
      !RUNNING_STATUSES.include?(query.pick(:status))
    end
  end

  def current_attempt?
    expected_attempt_token.nil? || expected_attempt_token == attempt_token
  end

  # The SDK saves its own assistant record after its final cancellation check.
  # Hold this lease through that save so recovery cannot race the SDK's write.
  def while_persistable
    with_lock do
      raise RubyLLM::CancelledError unless current_attempt?
      raise RubyLLM::CancelledError unless writing? || cancelling?

      yield
    end
  end

  def while_running
    with_lock do
      raise RubyLLM::CancelledError unless current_attempt? && RUNNING_STATUSES.include?(status)

      yield
    end
  end

  def fail!(message = FAILED_MESSAGE)
    with_lock do
      update!(status: "failed", error_message: message, finished_at: Time.current, heartbeat_at: Time.current) if current_attempt? && active? && !cancelling?
    end
  end

  def complete!
    with_lock do
      return false unless current_attempt? && active? && !cancelling?

      update!(status: "completed", error_message: nil, finished_at: Time.current, heartbeat_at: Time.current)
      true
    end
  end

  def heartbeat!
    return if heartbeat_at && heartbeat_at > 10.seconds.ago

    with_lock do
      return unless current_attempt? && RUNNING_STATUSES.include?(status)
      return if heartbeat_at && heartbeat_at > 10.seconds.ago

      touch(:heartbeat_at)
    end
  end

  def enqueue_job
    token = attempt_token
    job = ChatResponseJob.perform_later(chat_id, user_message.content,
      model: model_id, provider: provider, response_id: id, attempt_token: token)
    record_enqueue_failure(RuntimeError.new("Chat response job was not enqueued"), token) if job == false
    job
  rescue => error
    record_enqueue_failure(error, token)
  end

  def broadcast_status
    parent = Chat.find(chat_id)
    parent.with_lock do
      reload
      return unless self.class.where(chat_id: chat_id).maximum(:id) == id

      broadcast_replace_to "chat_#{chat_id}",
        target: "chat_#{chat_id}_response_status",
        partial: "chats/response_status",
        locals: {chat: parent, response: self}
    end
  rescue ActiveRecord::RecordNotFound
    # Deleting a conversation can race an already-committed status callback.
    nil
  rescue => error
    Rails.error.report(error, context: {chat_response_id: id, chat_id: chat_id})
  end

  private

  def assign_attempt_token
    self.attempt_token ||= SecureRandom.uuid
  end

  def dispatch
    enqueue_job
    broadcast_status
  end

  def record_enqueue_failure(error, token)
    with_lock do
      return unless attempt_token == token && queued?

      update!(status: "failed", error_message: FAILED_MESSAGE,
        finished_at: Time.current, heartbeat_at: Time.current)
    end
    Rails.error.report(error, context: {chat_response_id: id, chat_id: chat_id})
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def messages_belong_to_conversation
    if user_message && (user_message.chat_id != chat_id || user_message.role != "user" || user_message.content.blank?)
      errors.add(:user_message, "must be a nonempty question in this conversation")
    end
    if assistant_message && (assistant_message.chat_id != chat_id || assistant_message.role != "assistant")
      errors.add(:assistant_message, "must be an assistant reply in this conversation")
    end
  end
end
