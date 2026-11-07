class ExpireGuestChatsJob < ApplicationJob
  def perform
    Chat.expired_guest.find_each(&:destroy!)
  end
end
