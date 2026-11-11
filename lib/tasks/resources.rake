namespace :resources do
  # Saving an address queues its own lookup (see Address), but a lookup can fail,
  # for example during a geocoder outage. Run this to retry them. It's safe to run
  # again: addresses that already have coordinates are skipped, so a rerun only
  # retries the ones still missing.
  #
  # Resources saved before addresses had their own table keep their location in
  # metadata and are not looked up here. Editing or importing them again gives
  # them an address.
  #
  # This only queues jobs, so something has to be running to work through them. In
  # staging and production that's the Solid Queue workers inside Puma. Development
  # runs jobs inside the current process by default, so they'd be lost when this task
  # exits. Set SOLID_QUEUE_IN_PUMA=1 and keep the server running to use it locally.
  desc "Queue coordinate lookups for addresses with a street address but no coordinates"
  task geocode: :environment do
    queued = 0
    without_street = 0
    awaiting_enrichment = 0

    Address.where(lat: nil).or(Address.where(lng: nil)).includes(document: :source).find_each do |address|
      if address.document.awaiting_enrichment?
        # Enrichment may still fill in these addresses, and queues their lookups.
        awaiting_enrichment += 1
      elsif address.geocoding_query
        GeocodeAddressJob.perform_later(address)
        queued += 1
      else
        without_street += 1
      end
    end

    puts "Queued #{queued} coordinate lookups"
    puts "Skipped #{without_street} addresses with no coordinates and no street address"
    puts "Left #{awaiting_enrichment} addresses for enrichment to fill in" if awaiting_enrichment.positive?
  end
end
