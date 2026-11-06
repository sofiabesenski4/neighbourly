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

  # Optional place to measure distances from, as typed. FlyerOrigin looks it up when
  # the printout is generated, not here, because validating also runs for the live
  # preview, which shouldn't call an outside service.
  attribute :near, :string

  # Where the chosen location is, once it's known: from "Use my location", which the
  # browser's Geolocation API provides, or from checking a typed place on the first
  # screen. They arrive as text from hidden form fields.
  attribute :lat, :string
  attribute :lng, :string

  validates :near, length: {maximum: 200}
  validate :categories_are_available
  validate :coordinates_are_usable
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

  def near=(value)
    super(value.to_s.strip.presence)
  end

  def lat=(value)
    super(value.to_s.strip.presence)
  end

  def lng=(value)
    super(value.to_s.strip.presence)
  end

  # The submitted device location as a GeoPoint, or nil if there isn't a usable one.
  #
  # Rounded to 3 decimal places, about 100 m, which is plenty for walking estimates
  # and avoids handling someone's exact position. The browser code rounds too, so this
  # only matters for a request that didn't come from our page.
  def coordinates
    latitude = Float(lat, exception: false) if lat
    longitude = Float(lng, exception: false) if lng
    return unless latitude&.between?(-90, 90) && longitude&.between?(-180, 180)

    GeoPoint.new(lat: latitude.round(3), lng: longitude.round(3))
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

  def coordinates_are_usable
    return if lat.nil? && lng.nil?
    return if coordinates

    errors.add(:base, "We couldn't read your device's location. Try again, or type a nearby place.")
  end

  def categories_are_available
    if (unknown = categories - self.class.available_categories.keys).any?
      errors.add(:categories, "include unknown options: #{unknown.join(", ")}")
    end
  end
end
