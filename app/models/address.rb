# Where a resource is and how to reach it: its street address, city, phone
# number and coordinates. Each resource has at most one. Sources, the resource
# form and enrichment fill it in, and the printout, map and resource page read
# it.
#
# Resources saved before this table existed keep these details in their
# metadata. Document#location reads either.
#
# Service holds the same details for the resources people see. Until the
# printout and map read services, imports keep filling this in.
class Address < ApplicationRecord
  include Locatable

  belongs_to :document

  # The text to send to the geocoder, like "919 Pandora Ave, Victoria, BC", or
  # nil when this can't be looked up. A city alone gets no query, because that
  # could only match the middle of town.
  def geocoding_query
    street = street_address.to_s.strip
    [street, city.presence, "BC"].compact.join(", ") if street.present?
  end

  private

  def awaiting_enrichment?
    document.awaiting_enrichment?
  end

  def location_attributes
    %w[street_address city]
  end
end
