# Looks up where one address is and saves the answer on the address. The
# address can belong to a resource, a service or an organization.
#
# Architecture: Address queues this job after a save moves it to a street address
# with no coordinates. Enrichment queues it too, once it has filled in a CSV row's
# address. A background worker (Solid Queue) runs it later, calls Geocoder, and
# stores lat and lng on the address. The printout then reads those stored values
# without any network call.
#
# It's a background job rather than part of saving because the geocoder is an
# outside service. Whoever is saving a resource shouldn't have to wait for it,
# and a saved resource is still complete if the lookup fails: it just has no
# location until a later save or backfill finds one.
class GeocodeAddressJob < ApplicationJob
  # Importing a source can queue one job per resource. Running them one at a time
  # keeps a large import well under the geocoder's public limit of 1,000 requests
  # a minute. Solid Queue holds the rest until the current one finishes.
  limits_concurrency to: 1, key: "geocoder", duration: 1.minute

  # The service being down is usually temporary. Try up to 5 times in total,
  # waiting longer between each attempt. If the last attempt also fails, the error
  # is raised so the failure is visible, and the address stays without coordinates.
  retry_on Geocoder::Unavailable, wait: :polynomially_longer, attempts: 5

  # The resource was deleted before this job's turn came, so there's nothing to do.
  discard_on ActiveJob::DeserializationError

  def perform(address)
    # Queued jobs can run well after they were queued. Check the address still
    # needs a lookup: it may have been cleared or gained coordinates since.
    query = address.geocoding_query
    return if query.nil? || address.coordinates

    # nil means no trustworthy match. A retry would get the same answer, so stop.
    point = Geocoder.locate(query)
    return if point.nil?

    # A resource's address and its service usually hold the same address, and
    # each queues a lookup. The answer goes to both, so the second job finds
    # coordinates and skips its call.
    [address, *address.location_twins].each { |record| save_point(record, query, point) }
  end

  private

  def save_point(record, query, point)
    # Someone could edit the address during the network call. Lock its row and
    # reload it, so this can't overwrite that edit with an older copy.
    record.with_lock do
      # If the address changed during the lookup, these coordinates belong to the
      # old one. The edit will have queued its own lookup for the new one.
      next unless record.geocoding_query == query && record.coordinates.nil?

      # update_columns skips callbacks, so saving coordinates can't queue
      # another lookup.
      record.update_columns(lat: point.lat, lng: point.lng)
    end
  end
end
