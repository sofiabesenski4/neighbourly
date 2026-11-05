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

      chunks = parse(raw_content)

      Rails.logger.info "[ContentPipeline] Parsed #{chunks.size} chunks from #{@source.name}"

      chunks.each_with_index do |chunk, index|
        upsert_document(chunk)
        Rails.logger.info "[ContentPipeline] Embedded chunk #{index + 1}/#{chunks.size}"
      end

      enqueue_enrichment if @source.csv?
      @source.update!(last_fetched_at: Time.current)

      Rails.logger.info "[ContentPipeline] Finished ingesting #{@source.name}: #{chunks.size} documents"
      chunks.size
    end

    # Parse raw content into document chunks without writing anything. Raises
    # Parsers::ParseError when the content cannot be read.
    def parse(raw_content)
      @parser.parse(raw_content)
    end

    private

    # CSV rows arrive as raw "Header: value" text. Each new or changed row gets
    # its own job to summarize and categorize it, so one slow or failed LLM call
    # does not hold up the rest. Queued here so uploads and URL refreshes alike
    # get enriched.
    def enqueue_enrichment
      @source.documents.where(enriched_at: nil).find_in_batches do |documents|
        ActiveJob.perform_all_later(documents.map { |document| EnrichDocumentJob.new(document) })
      end
    end

    def parser_for(source)
      case source.source_type
      when "api"
        Parsers::Api.new(source)
      when "html"
        Parsers::Html.new(source)
      when "csv"
        Parsers::Csv.new(source)
      else
        raise ArgumentError, "Unknown source type: #{source.source_type}"
      end
    end

    def upsert_document(chunk)
      document = @source.documents.find_or_initialize_by(external_id: chunk[:external_id])
      return write_document(document, chunk) if document.new_record?

      # Enrichment may save this row while it is being replaced. Locking
      # reloads it, so a summary of the old row cannot survive on the new one.
      document.with_lock { write_document(document, chunk) }
    end

    def write_document(document, chunk)
      # An unchanged row keeps the summary and categories enrichment gave it.
      # A changed row is written fresh and enriched again.
      return if document.enriched_at? && document.metadata == chunk[:metadata]

      document.enriched_at = nil
      document.title = chunk[:title]
      document.content = chunk[:content]
      document.metadata = chunk[:metadata]
      document.save_with_category_names!(chunk[:categories] || [])
    end
  end
end
