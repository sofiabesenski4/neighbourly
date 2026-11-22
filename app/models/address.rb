# Where something is: its street address, city, province, postal code, country
# and coordinates. A resource (Document), a service or an organization has at
# most one, and only addresses hold coordinates. Sources, the admin forms and
# enrichment fill it in, and the printout, map and admin pages read it.
#
# A resource's address also keeps its phone number. Services and organizations
# keep theirs on the record itself.
#
# Resources saved before this table existed keep these details in their
# metadata. Document#location reads either.
class Address < ApplicationRecord
  # The BC Address Geocoder only knows BC, so it would match an address
  # elsewhere to the wrong place. These are the values that mean BC and Canada.
  BC_NAMES = ["bc", "b.c.", "british columbia"].freeze
  CANADA_NAMES = ["ca", "can", "canada"].freeze

  belongs_to :addressable, polymorphic: true

  # Data from the United States says "state".
  alias_attribute :state, :province

  normalizes :street_address, :city, :province, :postal_code, :country, :phone, with: ->(value) { value.strip.presence }

  # Coordinates describe one address. A save that moves the address without
  # giving new coordinates drops the old ones, and the lookup below finds new
  # ones. Coordinates given in the same save, such as from an import, are kept.
  before_save :forget_coordinates, if: -> { moved? && !lat_changed? && !lng_changed? }
  # after_commit, not after_save, so the job can't run before the address is
  # visible to the worker, or be queued for a save that gets rolled back.
  after_commit :locate_later, on: [:create, :update], if: :saved_move?

  # Sources can supply anything as coordinates. A value that isn't a number is
  # stored as unknown, rather than as 0, which would put the resource in the
  # ocean off Africa.
  def lat=(value)
    super(Float(value, exception: false))
  end

  def lng=(value)
    super(Float(value, exception: false))
  end

  # A GeoPoint, or nil when the location isn't known yet or the geocoder found
  # no trustworthy match. Callers must handle nil.
  def coordinates
    GeoPoint.new(lat: lat, lng: lng) if lat && lng
  end

  # The address as one line, like "919 Pandora Ave, Victoria, BC, V8W 1A1".
  def one_line
    [street_address, city, province, postal_code, country].compact_blank.join(", ")
  end

  # The text to send to the geocoder, like "919 Pandora Ave, Victoria, BC", or
  # nil when this can't be looked up. A city alone gets no query, because that
  # could only match the middle of town.
  def geocoding_query
    street = street_address.to_s.strip
    [street, city.presence, "BC"].compact.join(", ") if street.present? && in_bc?
  end

  # A missing province or country is taken to be BC, Canada, where every
  # resource so far is.
  def in_bc?
    (province.nil? || BC_NAMES.include?(province.downcase)) &&
      (country.nil? || CANADA_NAMES.include?(country.downcase))
  end

  # Queues a lookup when one could find coordinates. A service waiting for
  # enrichment is skipped, because enrichment may still fill in its address.
  # Enrichment calls this itself once it has saved.
  def locate_later
    return if geocoding_query.nil? || coordinates || awaiting_enrichment?

    GeocodeAddressJob.perform_later(self)
  end

  # True while enrichment may still fill in the service this address
  # belongs to. Rows and organizations are never enriched.
  def awaiting_enrichment?
    addressable.is_a?(Service) && addressable.awaiting_enrichment?
  end

  # A resource and the service read from it usually share an address, and
  # each queues a lookup. GeocodeAddressJob gives its answer to both.
  def location_twins
    twin = case addressable
    when Document then addressable.service
    when Service then addressable.document
    end
    [twin&.address].compact
  end

  private

  def moved?
    %w[street_address city province country].any? { |name| attribute_changed?(name) }
  end

  def saved_move?
    %w[street_address city province country].any? { |name| saved_change_to_attribute?(name) }
  end

  def forget_coordinates
    self.lat = nil
    self.lng = nil
  end
end
