# frozen_string_literal: true

return unless defined? Sentry

Sentry.init do |config|
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.dsn = ENV["SENTRY_DSN"]
  config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", 0.1).to_f

  # Deliberately off. This would attach request headers, IP addresses and user
  # identifiers to every event, and the people using this are often seeking
  # shelter, health or crisis services. An error report is not worth building a
  # record of who asked for help and from where.
  # https://docs.sentry.io/platforms/ruby/data-management/data-collected/
  config.send_default_pii = false
end
