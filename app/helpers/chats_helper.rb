module ChatsHelper
  def chat_title(chat)
    truncate(chat.title.presence || chat.first_user_message&.content.to_s.squish.presence || "New conversation", length: 80)
  end
end
