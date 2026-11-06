# Looks up where one resource is and saves the answer on that resource.
#
# Architecture: Document queues this job after a resource is saved with a street
# address and no coordinates. A background worker (Solid Queue) runs it later,
# calls Geocoder, and stores lat and lng in the resource's metadata. The printout
# then reads those stored values without any network call.
#
# It's a background job rather than part of saving because the geocoder is an
# outside service. Whoever is saving a resource shouldn't have to wait for it,
# and a saved resource is still complete if the lookup fails: it just has no
# location until a later save or backfill finds one.
class GeocodeDocumentJob < ApplicationJob
  # Importing a source can queue one job per resource. Running them one at a time
  # keeps a large import well under the geocoder's public limit of 1,000 requests
  # a minute. Solid Queue holds the rest until the current one finishes.
  limits_concurrency to: 1, key: "geocoder", duration: 1.minute

  # The service being down is usually temporary. Try up to 5 times in total,
  # waiting longer between each attempt. If the last attempt also fails, the error
  # is raised so the failure is visible, and the resource stays without coordinates.
  retry_on Geocoder::Unavailable, wait: :polynomially_longer, attempts: 5

  # The resource was deleted before this job's turn came, so there's nothing to do.
  discard_on ActiveJob::DeserializationError

  def perform(document)
    # Queued jobs can run well after they were queued. Check the resource still
    # needs a lookup: it may have lost its address or gained coordinates since.
    query = document.geocoding_query
    return if query.nil? || document.coordinates

    # nil means no trustworthy match. A retry would get the same answer, so stop.
    point = Geocoder.locate(query)
    return if point.nil?

    # Someone could edit the resource during the network call. Lock its row and
    # reload it, so this can't overwrite that edit with an older copy of metadata.
    document.with_lock do
      # If the address changed during the lookup, these coordinates belong to the
      # old address. The edit will have queued its own lookup for the new one.
      next unless document.geocoding_query == query

      # update_columns writes straight to the database and skips callbacks. A
      # normal save would run Document's callbacks for nothing, because
      # coordinates don't change the text that the search embedding is built from.
      document.update_columns(metadata: document.metadata.merge("lat" => point.lat, "lng" => point.lng))
    end
  end
end
