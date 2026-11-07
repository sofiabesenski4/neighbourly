namespace :resources do
  # Saving a resource queues its own lookup (see Document), but resources saved
  # before geocoding existed won't get one until someone edits them. Run this once
  # per environment to catch them up. It's safe to run again: resources that already
  # have coordinates are skipped, so a rerun only retries the ones still missing,
  # such as after a geocoder outage.
  #
  # This only queues jobs, so something has to be running to work through them. In
  # staging and production that's the Solid Queue workers inside Puma. Development
  # runs jobs inside the current process by default, so they'd be lost when this task
  # exits. Set SOLID_QUEUE_IN_PUMA=1 and keep the server running to use it locally.
  desc "Queue coordinate lookups for resources with an address but no coordinates"
  task geocode: :environment do
    queued = 0
    without_address = 0

    # Only id and metadata are needed. Leaving out the rest avoids loading every
    # resource's content and embedding vector into memory.
    Document.select(:id, :metadata).find_each do |document|
      next if document.coordinates

      if document.geocoding_query
        GeocodeDocumentJob.perform_later(document)
        queued += 1
      else
        without_address += 1
      end
    end

    puts "Queued #{queued} coordinate lookups"
    puts "Skipped #{without_address} resources with no coordinates and no street address"
  end
end
