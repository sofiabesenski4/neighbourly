namespace :sources do
  desc "Ingest a single source by ID"
  task :ingest, [:source_id] => :environment do |_t, args|
    source = Source.find(args[:source_id])
    count = ContentPipeline::Ingester.new(source).call
    puts "Ingested #{count} documents from '#{source.name}'"
  end

  desc "Fill in services still waiting for enrichment, for one source or all"
  task :enrich, [:source_id] => :environment do |_t, args|
    # Rows imported before their source started using AI are caught up too.
    imported_before = Service.where(enrichment_requested: false, enriched_at: nil, source: Source.where(enrich_documents: true))
      .where.not(document_id: nil)
    services = Service.where(enrichment_requested: true, enriched_at: nil).or(imported_before)
    services = services.where(source_id: args[:source_id]) if args[:source_id]
    failed = 0
    skipped = 0

    puts "Enriching #{services.count} services"
    services.find_each do |service|
      # A queued job may have enriched the service since this batch was loaded.
      service.reload
      service.update!(enrichment_requested: true) unless service.enrichment_requested? || service.enriched_at
      next skipped += 1 unless service.awaiting_enrichment?

      skipped += 1 unless ContentPipeline::Enricher.new(service).enrich!
    rescue RubyLLM::Error, Faraday::Error, ContentPipeline::Enricher::InvalidResponse,
      ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      failed += 1
      warn "Service #{service.id} was not enriched: #{e.message}"
    end
    puts "Finished enriching. #{failed} failed, #{skipped} skipped because they changed or were enriched meanwhile."
  end

  desc "Ingest all sources that have a URL to fetch"
  task ingest_all: :environment do
    Source.fetchable.find_each do |source|
      count = ContentPipeline::Ingester.new(source).call
      puts "Ingested #{count} documents from '#{source.name}'"
    end
  end
end
