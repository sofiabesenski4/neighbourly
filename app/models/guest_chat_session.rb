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

  def save_chats(id, user)
    return unless started? && id.match?(/\A[1-9]\d{0,18}\z/)

    Chat.transaction do
      # Lock in a consistent order if the tab submits sign-in twice.
      conversations = chats(Chat).order(:id).lock.to_a.select { |chat| owns?(chat) }
      conversations.each { |chat| chat.update!(user: user, guest_session_digest: nil) }
      conversations.find { |chat| chat.id.to_s == id } || conversations.last
    end
  end
end
