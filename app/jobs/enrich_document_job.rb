class EnrichDocumentJob < ApplicationJob
  # A large CSV queues one job per row. Chat replies run first, so a backlog
  # of summaries never keeps someone waiting for an answer.
  queue_with_priority 10

  # A row can be queued twice when its source is ingested again quickly.
  # Solid Queue holds the second job until the first finishes, and the second
  # then finds the row enriched and skips the paid call.
  limits_concurrency to: 1, key: ->(document) { document }, duration: 15.minutes

  # Rate limits, outages and dropped connections pass, so wait them out
  # rather than leave the row without a summary.
  retry_on RubyLLM::RateLimitError, RubyLLM::OverloadedError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError,
    Faraday::TimeoutError, Faraday::ConnectionFailed,
    wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(document)
    return if document.enriched_at? || !document.source.csv?

    ContentPipeline::Enricher.new(document).enrich!
  end
end
