class Category < ApplicationRecord
  has_and_belongs_to_many :documents
  has_and_belongs_to_many :services
  belongs_to :parent, class_name: "Category", optional: true, inverse_of: :children
  has_many :children, class_name: "Category", foreign_key: :parent_id, inverse_of: :parent

  validates :name, presence: true
  validate :parent_does_not_create_a_cycle

  private

  def parent_does_not_create_a_cycle
    seen = Set[self]
    ancestor = parent
    while ancestor
      unless seen.add?(ancestor)
        errors.add(:parent, "cannot create a category cycle")
        break
      end
      ancestor = ancestor.parent
    end
  end
end
