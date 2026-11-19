module ContentPipeline
  # Orchestrates the full ingestion pipeline for a Source:
  # fetch -> parse -> embed -> upsert documents.
  #
  # Two modes:
  #   Ingester.new(source).call           — fetches content from source URL
  #   Ingester.new(source).ingest(string) — ingests raw content directly (file upload)
  class Ingester
    # What a changed row no longer says is cleared from its service.
    CLEARED_SERVICE_FIELDS = %i[description hours phone email website]
      .index_with(nil).merge(closed: false, additional_details: {}).freeze
    CLEARED_ADDRESS_FIELDS = %i[street_address city province postal_code country].index_with(nil).freeze

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

      written = []
      begin
        chunks.each_with_index do |chunk, index|
          document = upsert_document(chunk)
          written << document if document
          Rails.logger.info "[ContentPipeline] Embedded chunk #{index + 1}/#{chunks.size}"
        end
      ensure
        # Rows saved before a later row fails are kept, so they are enriched too.
        enqueue_enrichment(written) if @source.enrich_documents?
      end
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

    # CSV rows arrive as raw "Header: value" text. Each row this run wrote
    # gets its own job to summarize and categorize it, so one slow or failed
    # LLM call does not hold up the rest. Queued here so uploads and URL
    # refreshes alike get enriched. Rows left waiting by earlier runs are
    # caught up by sources:enrich.
    def enqueue_enrichment(documents)
      documents.each_slice(1000) do |batch|
        ActiveJob.perform_all_later(batch.map { |document| EnrichDocumentJob.new(document) })
      end
    end

    def parser_for(source)
      case source.source_type
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

    # Returns the document when it was written, or nil when an unchanged
    # enriched row was kept as it was.
    def write_document(document, chunk)
      # An unchanged row keeps the summary and categories enrichment gave it.
      # A changed row is written fresh and enriched again.
      return if document.enriched_at? && Document.same_row?(document.metadata, chunk[:metadata])

      document.enriched_at = nil
      # The address is set again from what this row gives, which clears any
      # parts enrichment filled in for the old row.
      document.assign_address(**chunk[:address]) if chunk[:address]
      document.title = chunk[:title]
      document.content = chunk[:content]
      document.metadata = chunk[:metadata]
      # One transaction, so a row never ends up with a document but no
      # service, or a service read from an older version of the row.
      Document.transaction do
        document.save_with_category_names!(chunk[:categories] || [])
        write_service(document, chunk)
      end
      document
    end

    # The service this row describes, linked to the organization it names.
    # Like the resource, it is set again from a changed row, clearing what
    # enrichment filled in.
    def write_service(document, chunk)
      return unless chunk[:service]

      service = document.service || @source.services.build(document: document)
      service.assign_attributes(CLEARED_SERVICE_FIELDS.merge(chunk[:service]))
      write_service_address(service, chunk[:address] || {})
      service.organization = Organization.for_name(chunk.dig(:organization, :name), source: @source)
      service.categories = document.categories
      service.save!
    end

    # The service's address is where the row says, the same as the resource's.
    # Coordinates are only replaced when the row gives them, so a lookup
    # already made for the same address is kept.
    def write_service_address(service, row_address)
      location = row_address.slice(*CLEARED_ADDRESS_FIELDS.keys).compact_blank
      coordinates = row_address.slice(:lat, :lng).compact_blank
      return if service.address.nil? && location.empty? && coordinates.empty?

      (service.address || service.build_address).assign_attributes(CLEARED_ADDRESS_FIELDS.merge(location).merge(coordinates))
    end
  end
end
