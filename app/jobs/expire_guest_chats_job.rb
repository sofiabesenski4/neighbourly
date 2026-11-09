class ExpireGuestChatsJob < ApplicationJob
  def perform
    Chat.expired_guest.find_each do |chat|
      chat.with_lock do
        chat.destroy! if chat.guest? && chat.created_at <= Chat::GUEST_LIFETIME.ago
      end
    rescue ActiveRecord::RecordNotFound
      # Another worker or the tab may already have deleted it.
    end
  end
end
