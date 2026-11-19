class Category < ApplicationRecord
  has_and_belongs_to_many :documents
  has_and_belongs_to_many :services

  validates :name, presence: true
end
