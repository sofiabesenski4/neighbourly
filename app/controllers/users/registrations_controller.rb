# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
  # Registration is open, so without a limit an account farm can mint users in
  # a loop and each one gets its own LLM budget. The per-email tier stops a
  # retry loop on one address; the per-IP tier is the real control on bulk
  # signups, kept generous enough for a shelter onboarding several people at
  # once from one connection.
  rate_limit to: 3, within: 1.hour,
    by: -> { params.dig(:user, :email).to_s.downcase },
    with: -> { rate_limit_exceeded("An account request for that address is already in progress. Please try again shortly.") },
    only: :create, name: "per-email"
  rate_limit to: 20, within: 1.hour,
    by: -> { request.remote_ip },
    with: -> { rate_limit_exceeded("A lot of accounts have been created from this connection. Please try again later.") },
    only: :create, name: "per-ip"
end
