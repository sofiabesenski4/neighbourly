class GuestChatSession
  HEADER = "X-Neighbourly-Guest-Token"
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
end
