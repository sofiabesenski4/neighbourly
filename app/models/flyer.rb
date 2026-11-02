# Optional category filters for a printable flyer. An empty selection means
# all eligible resources.
# Not persisted; it validates the selection before handing it to
# FlyerGenerator.
class Flyer
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :categories, default: -> { [] }

  validate :categories_are_available

  # Category key => label for every option offered on the flyer form. These
  # are ResourceCategory keys, so each one matches the resources tagged with
  # it (see Document.in_category).
  def self.available_categories
    ResourceCategory.all.to_h { |category| [category.key, category.name] }
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
