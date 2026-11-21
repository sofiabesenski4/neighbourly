class EnrichServiceJob < ApplicationJob
  # A large CSV queues one job per row. Its own queue lets config/queue.yml
  # keep a worker free for chat replies, so a backlog of enrichment never
  # keeps someone waiting for an answer. Chat replies also run first on the
  # workers the two share.
  queue_as :enrichment
  queue_with_priority 10

  # A service can be queued twice when its source is ingested again quickly.
  # Solid Queue holds the second job until the first finishes, and the second
  # then finds the service enriched and skips the paid call.
  limits_concurrency to: 1, key: ->(service) { service }, duration: 15.minutes

  # Rate limits, outages and dropped connections pass, so wait them out
  # rather than leave the service unenriched.
  retry_on RubyLLM::RateLimitError, RubyLLM::OverloadedError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError,
    Faraday::TimeoutError, Faraday::ConnectionFailed,
    wait: :polynomially_longer, attempts: 5
  # Replies vary from call to call, so a reply without usable JSON or a
  # summary is worth asking for again, but only a couple of times. Services
  # that still fail are left for sources:enrich.
  retry_on ContentPipeline::Enricher::InvalidResponse, wait: 30.seconds, attempts: 3
  discard_on ActiveJob::DeserializationError

  def perform(service)
    return unless service.awaiting_enrichment?

    ContentPipeline::Enricher.new(service).enrich!
  end
end
