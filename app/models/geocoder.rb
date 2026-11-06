# Turns a BC address into a location, using the province's free BC Address
# Geocoder web service. This is the only code in the app that talks to that
# service, so its URL, reply format and match rules all live here.
#
# Architecture: GeocodeDocumentJob calls this in the background after a resource
# is saved, then stores the result in the resource's metadata. Printing reads
# those stored coordinates, so it doesn't depend on this service being up.
#
# Geocoder.locate has three possible outcomes, because callers need to treat
# them differently:
# - a GeoPoint: the service found the address and we trust the match.
# - nil: the service answered, but has no match we trust. Asking again won't help.
# - raises Unavailable: the service couldn't answer. Asking again later might work.
class Geocoder
  ENDPOINT = "https://geocoder.api.gov.bc.ca/addresses.json"

  # Seconds to wait for a connection, and again for a reply, before giving up.
  TIMEOUT = 5

  # The service scores each match from 0 to 100 for how closely its result fits
  # the text it was given. It always returns its best guess, however poor, so we
  # have to decide how low is too low.
  #
  # 90 comes from trying real addresses against the service:
  #   100  919 Pandora Ave, Victoria, BC       exact
  #    98  919 Pandoora Av, Victoria, BC       misspelled, still the right building
  #    94  919 Pandora, Victoria, BC           no "Ave", still the right building
  #    90  919 Pandora Ave, BC                 no city, still the right building
  #    88  123 Fake Street, Victoria, BC       WRONG: a house on Salt Spring Island
  #
  # That last one shows why precision alone isn't enough: it came back with
  # building-level precision. This is a small sample, so revisit the number if
  # real resources are being rejected or pinned in the wrong place.
  MINIMUM_SCORE = 90

  # How exact the match is, from the service's matchPrecision field. We accept a
  # specific building or unit, a block (one real address only matches this far)
  # and an intersection (for places people describe as "Douglas St and Yates St").
  #
  # STREET, LOCALITY and PROVINCE are left out. They put a resource in the middle
  # of a street or town, which looks believable on a map but is wrong.
  ACCEPTED_PRECISIONS = %w[SITE UNIT CIVIC_NUMBER BLOCK INTERSECTION].freeze

  # The service couldn't give an answer, as opposed to having no match. Lets
  # GeocodeDocumentJob know a retry is worthwhile.
  class Unavailable < StandardError; end

  def self.locate(address)
    uri = URI(ENDPOINT)
    # Only the best match is needed, so don't ask the service for more.
    uri.query = URI.encode_www_form(addressString: address, maxResults: 1)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri)
    end
    raise Unavailable, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    point_from(JSON.parse(response.body).fetch("features", []).first)
  rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError => error
    # Network failures, timeouts and garbled replies all mean the same thing to
    # a caller, so they're reported as one error.
    raise Unavailable, error.message
  end

  # Reads one match out of the service's reply, which is GeoJSON shaped like:
  #   {"geometry": {"coordinates": [-123.35, 48.42]},
  #    "properties": {"score": 100, "matchPrecision": "CIVIC_NUMBER"}}
  def self.point_from(feature)
    return if feature.nil?

    properties = feature.fetch("properties")
    return unless properties["score"].to_i >= MINIMUM_SCORE
    return unless ACCEPTED_PRECISIONS.include?(properties["matchPrecision"])

    # GeoJSON lists longitude first, the reverse of how people usually say it.
    # Everything past this point uses named fields, so this is the only place
    # the order matters.
    lng, lat = feature.dig("geometry", "coordinates")
    GeoPoint.new(lat: lat, lng: lng)
  end
  private_class_method :point_from
end
