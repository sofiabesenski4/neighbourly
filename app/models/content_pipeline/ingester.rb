module ContentPipeline
  # Orchestrates the full ingestion pipeline for a Source:
  # fetch -> parse -> embed -> upsert documents.
  #
  # Two modes:
  #   Ingester.new(source).call           — fetches content from source URL
  #   Ingester.new(source).ingest(string) — ingests raw content directly (file upload)
  class Ingester
    # What a changed row no longer says is cleared from its service, and
    # enrichment of the old details is redone. The service forgets an earlier
    # confirmation itself, only if a detail it vouched for now reads differently.
    CLEARED_SERVICE_FIELDS = %i[description hours phone email website enriched_at enriched_description embedding]
      .index_with(nil).merge(closed: false, additional_details: {}).freeze
    CLEARED_ADDRESS_FIELDS = %i[street_address city province postal_code country].index_with(nil).freeze

    # confirmed_by is the person uploading the content. Everything their
    # upload brings in counts as confirmed by them, changed or not.
    def initialize(source, confirmed_by: nil)
      @source = source
      @confirmed_by = confirmed_by
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
      rows = []
      begin
        chunks.each_with_index do |chunk, index|
          service = upsert_document(chunk)
          written << service if service
          rows << chunk[:external_id]
          Rails.logger.info "[ContentPipeline] Embedded chunk #{index + 1}/#{chunks.size}"
        end
      ensure
        # Rows saved before a later row fails are kept, so their services are
        # enriched and confirmed too.
        confirm_uploaded(rows)
        enqueue_enrichment(written)
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

    def confirm_uploaded(external_ids)
      return if @confirmed_by.nil? || external_ids.empty?

      @source.services.where(document: @source.documents.where(external_id: external_ids))
        .update_all(confirmed_at: Time.current, confirmed_by_id: @confirmed_by.id, confirmation_method: "upload")
    end

    # Each service this run left waiting for enrichment gets its own job, so
    # one slow or failed LLM call does not hold up the rest. Queued here so
    # uploads and URL refreshes alike get enriched. Services left waiting by
    # earlier runs are caught up by sources:enrich.
    def enqueue_enrichment(services)
      services.each_slice(1000) do |batch|
        ActiveJob.perform_all_later(batch.map { |service| EnrichServiceJob.new(service) })
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

      # Two imports of one source can overlap. Locking reloads the row, so the
      # later one sees what the earlier one wrote.
      document.with_lock { write_document(document, chunk) }
    end

    # Returns the row's service when it is waiting for enrichment, or nil.
    def write_document(document, chunk)
      # An unchanged row is left as it is, so its service keeps what
      # enrichment and people filled in. It only gets a service when it has
      # none, as when an admin deleted it. Web page chunks are always written:
      # their metadata doesn't hold their text.
      if chunk[:service] && document.persisted? && Document.same_row?(document.metadata, chunk[:metadata])
        write_service(document, chunk) if document.service.nil?
        request_enrichment(document.service)
        return waiting_service(document)
      end

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
      waiting_service(document)
    end

    # A source that started using AI after this row was imported asks for
    # the row's service to be filled in, once.
    def request_enrichment(service)
      return unless @source.enrich_documents? && service && !service.enrichment_requested? && service.enriched_at.nil?

      service.lock!.request_enrichment
      service.save!
    end

    def waiting_service(document)
      service = document.service
      service if service&.awaiting_enrichment?
    end

    # The service this row describes, linked to the organization it names.
    # Like the resource, it is set again from a changed row, clearing what
    # enrichment filled in. A source with AI summaries turned on asks for it
    # to be enriched again.
    def write_service(document, chunk)
      return unless chunk[:service]

      # Enrichment may have saved this service since it was loaded. Locking
      # reloads it, so clearing what enrichment wrote clears it for real.
      service = document.service&.lock! || @source.services.build(document: document)
      service.assign_attributes(CLEARED_SERVICE_FIELDS.merge(chunk[:service]))
      service.enrichment_requested = @source.enrich_documents?
      # Enrichment names a service whose row had no name column. Without it,
      # the row's title, its first value, has to do.
      service.name ||= document.title unless service.awaiting_enrichment?
      write_service_address(service, chunk[:address] || {})
      # A service stays with its organization while the row names it by any
      # name it has had, even if another organization now uses an old one.
      name = chunk.dig(:organization, :name)
      service.organization = Organization.for_name(name, source: @source) unless service.organization&.goes_by?(name)
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
