namespace :sources do
  desc "Ingest a single source by ID"
  task :ingest, [:source_id] => :environment do |_t, args|
    source = Source.find(args[:source_id])
    count = ContentPipeline::Ingester.new(source).call
    puts "Ingested #{count} documents from '#{source.name}'"
  end

  desc "Summarize and categorize CSV documents not yet enriched, for one source or all"
  task :enrich, [:source_id] => :environment do |_t, args|
    sources = Source.csv_sources
    sources = sources.where(id: args[:source_id]) if args[:source_id]
    documents = Document.where(source: sources, enriched_at: nil)
    failed = 0

    puts "Enriching #{documents.count} documents"
    documents.find_each do |document|
      ContentPipeline::Enricher.new(document).enrich!
    rescue RubyLLM::Error, ContentPipeline::Enricher::InvalidResponse, ActiveRecord::RecordNotSaved => e
      failed += 1
      warn "Document #{document.id} was not enriched: #{e.message}"
    end
    puts "Finished enriching. #{failed} failed."
  end

  desc "Ingest all sources that have a URL to fetch"
  task ingest_all: :environment do
    Source.fetchable.find_each do |source|
      count = ContentPipeline::Ingester.new(source).call
      puts "Ingested #{count} documents from '#{source.name}'"
    end
  end
end
