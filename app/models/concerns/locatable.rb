# Coordinates for a record with a street address, found by GeocodeAddressJob.
# Address and Service both use it, so a resource is placed on the map the same
# way whichever one holds its address.
#
# The including model defines:
#   geocoding_query     the text sent to the geocoder, or nil for no lookup
#   awaiting_enrichment? true while enrichment may still fill in the address
#   location_attributes  the columns that, when changed, move the record
module Locatable
  extend ActiveSupport::Concern

  included do
    # Coordinates describe one address. A save that moves the address without
    # giving new coordinates drops the old ones, and the lookup below finds new
    # ones. Coordinates given in the same save, such as from an import, are kept.
    before_save :forget_coordinates, if: -> { moved? && !lat_changed? && !lng_changed? }
    # after_commit, not after_save, so the job can't run before the record is
    # visible to the worker, or be queued for a save that gets rolled back.
    after_commit :locate_later, on: [:create, :update], if: :saved_move?
  end

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

  # Queues a lookup when one could find coordinates. A row waiting for
  # enrichment is skipped, because enrichment may still fill in its address.
  # Enrichment calls this itself once it has saved.
  def locate_later
    return if geocoding_query.nil? || coordinates || awaiting_enrichment?

    GeocodeAddressJob.perform_later(self)
  end

  private

  def moved?
    location_attributes.any? { |name| attribute_changed?(name) }
  end

  def saved_move?
    location_attributes.any? { |name| saved_change_to_attribute?(name) }
  end

  def forget_coordinates
    self.lat = nil
    self.lng = nil
  end
end
