namespace :sources do
  desc "Ingest a single source by ID"
  task :ingest, [:source_id] => :environment do |_t, args|
    source = Source.find(args[:source_id])
    count = ContentPipeline::Ingester.new(source).call
    puts "Ingested #{count} documents from '#{source.name}'"
  end

  desc "Ingest all sources"
  task ingest_all: :environment do
    Source.find_each do |source|
      count = ContentPipeline::Ingester.new(source).call
      puts "Ingested #{count} documents from '#{source.name}'"
    end
  end
end
