# Optional category filters for a printable flyer. An empty selection means
# all eligible resources.
# Not persisted; it validates the selection before handing it to
# FlyerGenerator.
class Flyer
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :categories, default: -> { [] }

  validate :categories_are_available

  # Use the same persisted categories as the resource form. String IDs match
  # submitted checkbox values without coercing malformed input into an ID.
  def self.available_categories
    Category.order(:name, :id).pluck(:id, :name).to_h.transform_keys(&:to_s)
  end

  def categories=(value)
    super(Array(value).compact_blank.map(&:to_s).uniq)
  end

  private

  def categories_are_available
    if (unknown = categories - self.class.available_categories.keys).any?
      errors.add(:categories, "include unknown options: #{unknown.join(", ")}")
    end
  end
end
