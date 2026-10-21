# The set of information a user has chosen to include on a printable flyer.
# Not persisted; it validates the selection before handing it to
# FlyerGenerator.
class Flyer
  include ActiveModel::Model
  include ActiveModel::Attributes

  CATEGORIES = {
    "food" => "Food",
    "shelter" => "Shelter & housing",
    "substance_use" => "Substance use support",
    "employment" => "Employment",
    "health" => "Health care",
    "mental_health" => "Mental health",
    "legal" => "Legal aid",
    "clothing_hygiene" => "Clothing & hygiene"
  }.freeze

  attribute :categories, default: -> { [] }

  validate :categories_are_available

  # Category key => label for every option offered on the flyer form. This is
  # the one place to change if the list should come from what's in the
  # database instead of being hardcoded.
  def self.available_categories
    CATEGORIES
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
