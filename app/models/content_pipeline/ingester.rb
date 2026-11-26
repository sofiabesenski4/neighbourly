module ContentPipeline
  # Orchestrates the full ingestion pipeline for a Source:
  # fetch -> parse -> embed -> upsert documents.
  #
  # Two modes:
  #   Ingester.new(source).call           — fetches content from source URL
  #   Ingester.new(source).ingest(string) — ingests raw content directly (file upload)
  class Ingester
    # What a changed row no longer says is cleared from its service, once an
    # admin approves clearing a detail the service has a value for. The
    # service forgets an earlier confirmation itself, only if a detail it
    # vouched for now reads differently.
    CLEARED_SERVICE_FIELDS = %i[description hours phone email website]
      .index_with(nil).merge(closed: false, additional_details: {}).freeze

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
          document = upsert_document(chunk)
          written << document if document
          rows << chunk[:external_id]
          Rails.logger.info "[ContentPipeline] Embedded chunk #{index + 1}/#{chunks.size}"
        end
      ensure
        # Rows saved before a later row fails are kept, so they are enriched
        # and confirmed too.
        confirm_uploaded(rows)
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

    # A service with details waiting for an admin still shows values the
    # upload didn't give, so it keeps the confirmation it had for them.
    def confirm_uploaded(external_ids)
      return if @confirmed_by.nil? || external_ids.empty?

      @source.services.where(document: @source.documents.where(external_id: external_ids))
        .where.not(id: ImportConflict.pending.select(:service_id))
        .update_all(confirmed_at: Time.current, confirmed_by_id: @confirmed_by.id, confirmation_method: "upload")
    end

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

    # Returns the document when enrichment may still be due for it, or nil
    # when an unchanged enriched row was kept as it was.
    def write_document(document, chunk)
      # An unchanged row is left as it is, so it keeps the summary and
      # categories enrichment gave it, and admins' edits to its service. It
      # only gets a service when it has none, as when an admin deleted it. Web
      # page chunks are always written: their metadata doesn't hold their text.
      if chunk[:service] && document.persisted? && Document.same_row?(document.metadata, chunk[:metadata])
        write_service(document, chunk) if document.service.nil?
        return document.enriched_at? ? nil : document
      end

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

    # The service this row describes, linked to the organization it names and
    # at the address it gives, the same as the resource's. A detail the
    # service already has a different value for waits for an admin to choose
    # which to keep (see ImportConflict).
    def write_service(document, chunk)
      return unless chunk[:service]

      service = document.service || @source.services.build(document: document)
      address = (chunk[:address] || {}).stringify_keys.slice(*ImportConflict::LOCATION_FIELDS, "lat", "lng").compact_blank
      service.take_import(CLEARED_SERVICE_FIELDS.merge(chunk[:service])
        .merge(organization: chunk.dig(:organization, :name), address: address))
      service.categories = document.categories
      service.save!
    end
  end
end
