# Optional search and filters for a printable flyer. An empty selection means
# all eligible resources in the default guide order.
# Not persisted; it validates the selection before handing it to
# FlyerGenerator.
class Flyer
  include ActiveModel::Model
  include ActiveModel::Attributes

  DEFAULT_SORT = "default"
  SORT_OPTIONS = {"Guide order" => DEFAULT_SORT, "Resource name A–Z" => "asc", "Resource name Z–A" => "desc"}.freeze
  QUERY_LIMIT = 160

  attribute :categories, default: -> { [] }
  attribute :query, :string, default: ""
  attribute :sort, :string, default: DEFAULT_SORT

  validate :categories_are_available
  validates :query, length: {maximum: QUERY_LIMIT}
  validates :sort, inclusion: {in: SORT_OPTIONS.values}

  # Use the same persisted categories as the resource form. String IDs match
  # submitted checkbox values without coercing malformed input into an ID.
  def self.available_categories
    Category.order(:name, :id).pluck(:id, :name).to_h.transform_keys(&:to_s)
  end

  def categories=(value)
    super(Array(value).compact_blank.map(&:to_s).uniq)
  end

  def query=(value)
    super(value.to_s.strip)
  end

  def filters
    {categories: categories}.tap do |filters|
      filters[:query] = query if query.present?
      filters[:sort] = sort if sort != DEFAULT_SORT
    end
  end

  private

  def categories_are_available
    if (unknown = categories - self.class.available_categories.keys).any?
      errors.add(:categories, "include unknown options: #{unknown.join(", ")}")
    end
  end
end
