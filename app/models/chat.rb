class Chat < ApplicationRecord
  acts_as_chat

  belongs_to :user

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
