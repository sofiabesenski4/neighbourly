# A service chat found for a message, like DocumentMessage for imported rows.
class ServiceMessage < ApplicationRecord
  belongs_to :service
  belongs_to :message
end
