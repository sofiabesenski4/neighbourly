class GuestChatSession
  HEADER = "X-Neighbourly-Guest-Token"
  SAVE_CHAT_HEADER = "X-Neighbourly-Guest-Chat"
  KEY_FORMAT = /\A[0-9a-f]{64}\z/

  attr_reader :digest

  def initialize(tab_key)
    @digest = Digest::SHA256.hexdigest(tab_key) if tab_key.is_a?(String) && KEY_FORMAT.match?(tab_key)
  end

  def started?
    digest.present?
  end

  def chats(scope)
    return scope.none unless digest

    scope.active_guest.where(guest_session_digest: digest)
  end

  def owns?(chat)
    chat.guest? && chat.guest_session_digest == digest && chat.created_at > Chat::GUEST_LIFETIME.ago
  end

  def save_chat(id, user)
    return unless started? && id.match?(/\A[1-9]\d{0,18}\z/)

    Chat.transaction do
      chat = chats(Chat).lock.find_by(id: id)
      if chat && owns?(chat)
        chat.update!(user: user, guest_session_digest: nil)
        chat
      end
    end
  end
end
