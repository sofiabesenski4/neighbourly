# frozen_string_literal: true

# Action Controller emits this whenever a request trips a rate limit. Reporting
# it gives us a way to tell whether a limit is too tight before users start
# complaining, and a signal when someone is actually probing us.
#
# The `by` value is the rate limit's identity key, which for sign-in and
# password reset is a user's email address. filter_parameters keeps emails out
# of the request log and it should not sneak back in here, so only ever report
# a short digest of it: enough to tell two offenders apart, not enough to
# recover the address.
ActiveSupport::Notifications.subscribe("rate_limit.action_controller") do |event|
  payload = event.payload
  identity = OpenSSL::Digest::SHA256.hexdigest(payload[:by].to_s).first(12)

  context = {
    scope: payload[:scope],
    limit_name: payload[:name],
    count: payload[:count],
    to: payload[:to],
    within: payload[:within].to_i,
    identity_digest: identity
  }

  Rails.logger.warn("[RateLimit] exceeded #{context.map { |k, v| "#{k}=#{v}" }.join(" ")}")

  if defined?(Sentry) && Sentry.initialized?
    Sentry.capture_message(
      "Rate limit exceeded: #{payload[:scope]}##{payload[:name]}",
      level: :warning,
      extra: context
    )
  end
end
