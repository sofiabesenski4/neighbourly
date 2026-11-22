# Optional search and filters for a printable flyer. An empty selection means
# all eligible resources in the default guide order.
# Not persisted; it validates the selection before handing it to
# FlyerGenerator.
class Flyer
  include ActiveModel::Model
  include ActiveModel::Attributes

  DEFAULT_SORT = "default"
  DISTANCE_SORT = "distance"
  SORT_OPTIONS = {"Category" => DEFAULT_SORT, "Name (A–Z)" => "asc", "Name (Z–A)" => "desc", "Distance" => DISTANCE_SORT}.freeze
  QUERY_LIMIT = 160
  DETAIL_LEVELS = %w[summary detailed].freeze

  attribute :categories, default: -> { [] }
  attribute :service_ids
  attribute :organizations, default: -> { [] }
  attribute :query, :string, default: ""
  attribute :sort, :string, default: DEFAULT_SORT
  attribute :detail_level, :string, default: "detailed"

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
  validate :service_ids_are_usable
  validate :organizations_are_available
  validate :coordinates_are_usable
  validates :query, length: {maximum: QUERY_LIMIT}
  validates :sort, inclusion: {in: SORT_OPTIONS.values}
  validates :detail_level, inclusion: {in: DETAIL_LEVELS}

  # Use the same persisted categories as the resource form. String IDs match
  # submitted checkbox values without coercing malformed input into an ID.
  def self.available_categories
    Category.order(:name, :id).pluck(:id, :name).to_h.transform_keys(&:to_s)
  end

  def categories=(value)
    super(Array(value).compact_blank.map(&:to_s).uniq)
  end

  # Organizations offering at least one service a printout could list, by ID
  # as a string, like available_categories.
  def self.available_organizations
    Organization.where(id: Service.visible.select(:organization_id)).alphabetical.pluck(:id, :name).to_h.transform_keys(&:to_s)
  end

  def organizations=(value)
    super(Array(value).compact_blank.map(&:to_s).uniq)
  end

  # A missing list is the standard form submission. An explicit empty list
  # means the person removed every resource from their printout.
  def service_ids=(value)
    super(value.nil? ? nil : Array(value).compact_blank.map(&:to_s).uniq)
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
      filters[:organizations] = organizations if organizations.any?
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

  def organizations_are_available
    if (unknown = organizations - self.class.available_organizations.keys).any?
      errors.add(:organizations, "include unknown options: #{unknown.join(", ")}")
    end
  end

  def categories_are_available
    if (unknown = categories - self.class.available_categories.keys).any?
      errors.add(:categories, "include unknown options: #{unknown.join(", ")}")
    end
  end

  def service_ids_are_usable
    return if service_ids.nil?

    if service_ids.empty?
      errors.add(:base, "Choose at least one resource to include in your printout.")
    elsif service_ids.any? { |id| !id.match?(/\A[1-9][0-9]{0,18}\z/) || id.to_i > 2**63 - 1 }
      errors.add(:base, "The selected resources could not be read.")
    end
  end
end
