class Chat < ApplicationRecord
  acts_as_chat

  GUEST_LIFETIME = 24.hours

  belongs_to :user, optional: true
  has_one :first_user_message, -> { where(role: "user").order(:id) }, class_name: "Message"
  has_many :chat_responses, dependent: :destroy

  validates :title, length: {maximum: 60}, allow_nil: true
  validate :require_one_owner

  after_update_commit :broadcast_title, if: :saved_change_to_title?

  scope :guest, -> { where.not(guest_session_digest: nil) }
  scope :active_guest, -> { guest.where("created_at > ?", GUEST_LIFETIME.ago) }
  scope :expired_guest, -> { guest.where(created_at: ..GUEST_LIFETIME.ago) }

  def guest?
    guest_session_digest.present?
  end

  # A guest subscription issued before sign-in cannot receive account messages.
  def stream_name
    guest? ? "chat_#{id}" : "account_#{user_id}_chat_#{id}"
  end

  def response_in_progress?
    chat_responses.active.exists?
  end

  def latest_response
    chat_responses.order(:id).last
  end

  def broadcast_title
    broadcast_update_to stream_name,
      targets: "[data-chat-title='#{id}'], head title",
      partial: "chats/title",
      locals: {chat: self}
  end

  def broadcast_reply_failed
    # Turbo replaces an existing direct child with the same ID on append.
    broadcast_append_to stream_name,
      target: "messages",
      partial: "messages/reply_failed",
      locals: {chat: self}
  end

  def broadcast_reply_succeeded
    broadcast_remove_to stream_name, target: "chat_#{id}_reply_failed"
  end

  private

  def require_one_owner
    return if user.present? != guest?

    errors.add(:base, "A conversation must belong to an account or a guest session.")
  end
end
