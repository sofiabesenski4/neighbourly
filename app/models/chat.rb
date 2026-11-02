class Chat < ApplicationRecord
  acts_as_chat

  belongs_to :user
  has_one :first_user_message, -> { where(role: "user").order(:id) }, class_name: "Message"
  has_many :chat_responses, dependent: :destroy

  validates :title, length: {maximum: 60}, allow_nil: true

  after_update_commit :broadcast_title, if: :saved_change_to_title?

  def response_in_progress?
    chat_responses.active.exists?
  end

  def latest_response
    chat_responses.order(:id).last
  end

  def broadcast_title
    broadcast_update_to "chat_#{id}",
      targets: "[data-chat-title='#{id}'], head title",
      partial: "chats/title",
      locals: {chat: self}
  end

  def broadcast_reply_failed
    # Turbo replaces an existing direct child with the same ID on append.
    broadcast_append_to "chat_#{id}",
      target: "messages",
      partial: "messages/reply_failed",
      locals: {chat: self}
  end

  def broadcast_reply_succeeded
    broadcast_remove_to "chat_#{id}", target: "chat_#{id}_reply_failed"
  end
end
