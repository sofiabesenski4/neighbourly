class Chat < ApplicationRecord
  acts_as_chat

  belongs_to :user

  def broadcast_reply_failed
    broadcast_append_to "chat_#{id}",
      target: "messages",
      partial: "messages/reply_failed"
  end
end
