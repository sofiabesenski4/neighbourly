namespace :sources do
  desc "Ingest a single source by ID"
  task :ingest, [:source_id] => :environment do |_t, args|
    source = Source.find(args[:source_id])
    count = ContentPipeline::Ingester.new(source).call
    puts "Ingested #{count} documents from '#{source.name}'"
  end

  desc "Summarize and categorize CSV documents not yet enriched, for one opted-in source or all"
  task :enrich, [:source_id] => :environment do |_t, args|
    sources = Source.csv_sources.where(enrich_documents: true)
    sources = sources.where(id: args[:source_id]) if args[:source_id]
    documents = Document.where(source: sources, enriched_at: nil)
    failed = 0
    skipped = 0

    puts "Enriching #{documents.count} documents"
    documents.find_each do |document|
      # A queued job may have enriched the row since this batch was loaded.
      next skipped += 1 if document.reload.enriched_at?

      skipped += 1 unless ContentPipeline::Enricher.new(document).enrich!
    rescue RubyLLM::Error, Faraday::Error, ContentPipeline::Enricher::InvalidResponse,
      ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotFound => e
      failed += 1
      warn "Document #{document.id} was not enriched: #{e.message}"
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
