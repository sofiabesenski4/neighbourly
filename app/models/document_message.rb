class DocumentMessage < ApplicationRecord
  belongs_to :document
  belongs_to :message
end
