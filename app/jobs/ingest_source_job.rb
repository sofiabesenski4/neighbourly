# Ingests a Source's uploaded file outside the web request, since embedding
# every row can take longer than a request may run. The upload is held on the
# source until it is ingested, so any worker process can read it and a failed
# run can be retried.
class IngestSourceJob < ApplicationJob
  # Two runs for one source would write the same documents at once, and the
  # loser's unique-index error would mark the source failed mid-ingestion.
  # Solid Queue holds a second run until the first finishes.
  limits_concurrency to: 1, key: ->(source) { source }, duration: 1.hour

  # The source was deleted before its upload was ingested.
  discard_on ActiveJob::DeserializationError

  def perform(source)
    return if source.upload_content.nil?

    source.update!(ingestion_status: :ingesting, ingestion_error: nil)
    ContentPipeline::Ingester.new(source).ingest(source.upload_content)
    enqueue_enrichment(source) if source.csv?
    source.update!(ingestion_status: :succeeded, upload_content: nil)
  rescue => e
    # Reload first: a document that failed to save is still in the in-memory
    # association, and saving the source would validate it again.
    source.reload.update!(ingestion_status: :failed, ingestion_error: failure_message(e))
    raise
  end

  private

  # CSV rows arrive as raw "Header: value" text. Each new or changed row gets
  # its own job to summarize and categorize it, so one slow or failed LLM call
  # does not hold up the rest.
  def enqueue_enrichment(source)
    source.documents.where(enriched_at: nil).find_in_batches do |documents|
      ActiveJob.perform_all_later(documents.map { |document| EnrichDocumentJob.new(document) })
    end
  end

  # A document that fails to save raises a generic "Failed to save the record".
  # Its validation errors say why, such as the embedding service being down.
  def failure_message(error)
    errors = error.try(:record)&.errors
    errors.present? ? errors.full_messages.to_sentence : error.message
  end
end
