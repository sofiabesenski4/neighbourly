# The set of information a user has chosen to include on a printable flyer.
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
    if categories.empty?
      errors.add(:categories, "must include at least one type of information")
    elsif (unknown = categories - self.class.available_categories.keys).any?
      errors.add(:categories, "include unknown options: #{unknown.join(", ")}")
    end
  end
end
