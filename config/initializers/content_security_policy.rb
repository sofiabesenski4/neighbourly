Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src :self
    policy.img_src :self
    policy.object_src :none
    policy.script_src :self
    policy.style_src :self
    policy.connect_src :self, "ws://localhost:*", "wss://localhost:*"
    policy.frame_src :none
    policy.base_uri :self
    policy.form_action :self
    policy.frame_ancestors :none

    if Rails.env.production? || Rails.env.staging?
      policy.connect_src :self, :https, "wss:"
    end
  end

  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[style-src]

  # Enforced, not report-only: we render model output into pages, so the policy
  # has to actually stop something. There are no inline scripts or styles in any
  # view, so nothing legitimate needs an exemption.
  config.content_security_policy_report_only = false
end
