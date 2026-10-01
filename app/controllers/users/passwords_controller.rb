# frozen_string_literal: true

class Users::PasswordsController < Devise::PasswordsController
  # This form sends mail from our domain to any address someone types, so an
  # unlimited version is both an inbox-flooding tool and a fast way to burn our
  # sending reputation. Limit tightly on the address being mailed and cap how
  # much mail one connection can trigger overall.
  rate_limit to: 3, within: 15.minutes,
    by: -> { params.dig(:user, :email).to_s.downcase },
    with: -> { rate_limit_exceeded("We've already sent reset instructions to that address. Please check your inbox, including spam.") },
    only: :create, name: "per-email"
  rate_limit to: 20, within: 1.hour,
    by: -> { request.remote_ip },
    with: -> { rate_limit_exceeded("Too many password reset requests from this connection. Please try again later.") },
    only: :create, name: "per-ip"
end
