module ContentPipeline
  # Orchestrates the full ingestion pipeline for a Source:
  # fetch -> parse -> embed -> upsert documents.
  #
  # Two modes:
  #   Ingester.new(source).call           — fetches content from source URL
  #   Ingester.new(source).ingest(string) — ingests raw content directly (file upload)
  class Ingester
    def initialize(source)
      @source = source
      @parser = parser_for(source)
    end

    # Fetch from the source URL and ingest.
    def call
      raw_content = Fetcher.new(@source).call
      ingest(raw_content)
    end

    # Ingest raw content directly (e.g. from a file upload).
    def ingest(raw_content)
      Rails.logger.info "[ContentPipeline] Ingesting source: #{@source.name} (#{@source.source_type})"

      chunks = @parser.parse(raw_content)

      Rails.logger.info "[ContentPipeline] Parsed #{chunks.size} chunks from #{@source.name}"

      chunks.each_with_index do |chunk, index|
        upsert_document(chunk)
        Rails.logger.info "[ContentPipeline] Embedded chunk #{index + 1}/#{chunks.size}"
      end

      @source.update!(last_fetched_at: Time.current)

      Rails.logger.info "[ContentPipeline] Finished ingesting #{@source.name}: #{chunks.size} documents"
      chunks.size
    end

    private

    def parser_for(source)
      case source.source_type
      when "api"
        Parsers::Api.new(source)
      when "html"
        Parsers::Html.new(source)
      else
        raise ArgumentError, "Unknown source type: #{source.source_type}"
      end
    end

    def upsert_document(chunk)
      document = @source.documents.find_or_initialize_by(external_id: chunk[:external_id])
      document.title = chunk[:title]
      document.content = chunk[:content]
      document.metadata = chunk[:metadata]
      document.save!
    end
  end
end
