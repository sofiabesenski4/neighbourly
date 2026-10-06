class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  include Pundit::Authorization

  before_action :enforce_basic_auth

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  def enforce_basic_auth
    return if ENV["BASIC_AUTH_ENABLED"] == "false"

    authenticate_or_request_with_http_basic do |username, password|
      ActiveSupport::SecurityUtils.secure_compare(username, ENV.fetch("BASIC_AUTH_USERNAME")) &
        ActiveSupport::SecurityUtils.secure_compare(password, ENV.fetch("BASIC_AUTH_PASSWORD"))
    end
  end

  # Shared `with:` handler for rate_limit. Someone looking for a shelter bed
  # should not be met with a bare 429 page, so send them back where they were
  # with an explanation they can act on.
  def rate_limit_exceeded(message)
    redirect_back fallback_location: root_path, alert: message
  end

  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    redirect_back(fallback_location: user_signed_in? ? root_path : new_user_session_path)
  end

  private

  def available_chat_models
    RubyLLM.models.chat_models.all
      .sort_by { |model| [model.provider.to_s, model.name.to_s] }
  end
end
