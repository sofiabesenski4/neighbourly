class EnrichDocumentJob < ApplicationJob
  # Rate limits and outages pass, so wait them out rather than leave the row
  # without a summary.
  retry_on RubyLLM::RateLimitError, RubyLLM::OverloadedError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError,
    wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(document)
    # A row can be queued twice when its source is ingested again quickly.
    return if document.enriched_at? || !document.source.csv?

    ContentPipeline::Enricher.new(document).enrich!
  end
end
