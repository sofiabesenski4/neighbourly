# Where a resource is and how to reach it: its street address, city, phone
# number and coordinates. Each resource has at most one. Sources, the resource
# form and enrichment fill it in, and the printout, map and resource page read
# it.
#
# Resources saved before this table existed keep these details in their
# metadata. Document#location reads either.
class Address < ApplicationRecord
  belongs_to :document

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

  # The text to send to the geocoder, like "919 Pandora Ave, Victoria, BC", or
  # nil when this can't be looked up. A city alone gets no query, because that
  # could only match the middle of town.
  def geocoding_query
    street = street_address.to_s.strip
    [street, city.presence, "BC"].compact.join(", ") if street.present?
  end

  # Queues a lookup when one could find coordinates. A row waiting for
  # enrichment is skipped, because enrichment may still fill in its address.
  # Enrichment calls this itself once it has saved.
  def locate_later
    return if geocoding_query.nil? || coordinates || document.awaiting_enrichment?

    GeocodeAddressJob.perform_later(self)
  end

  private

  def moved?
    street_address_changed? || city_changed?
  end

  def saved_move?
    saved_change_to_street_address? || saved_change_to_city?
  end

  def forget_coordinates
    self.lat = nil
    self.lng = nil
  end
end
