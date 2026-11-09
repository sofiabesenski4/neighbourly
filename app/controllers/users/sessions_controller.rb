# frozen_string_literal: true

class Users::SessionsController < Devise::SessionsController
  # Devise's :lockable module is not enabled, so nothing capped password
  # guessing before this. Limit on the account being attacked rather than the
  # IP alone: our users share connections at shelters and libraries, and one
  # person fumbling a password should not lock the room out of signing in.
  rate_limit to: 10, within: 20.minutes,
    by: -> { params.dig(:user, :email).to_s.downcase },
    with: -> { rate_limit_exceeded("Too many sign-in attempts for that account. Please wait a few minutes and try again.") },
    only: :create, name: "per-email"
  rate_limit to: 100, within: 1.hour,
    by: -> { request.remote_ip },
    with: -> { rate_limit_exceeded("Too many sign-in attempts from this connection. Please try again later.") },
    only: :create, name: "per-ip"

  # GET /resource/sign_in
  # def new
  #   super
  # end

  def create
    super do |user|
      chat_id = request.headers[GuestChatSession::SAVE_CHAT_HEADER]
      if chat_id.present?
        guest = GuestChatSession.new(request.headers[GuestChatSession::HEADER])
        @saved_guest_chat = guest.save_chat(chat_id, user)
        if @saved_guest_chat
          flash[:notice] = "Chat saved to your account."
        else
          flash[:alert] = "This guest chat is no longer available to save."
        end
      end
    end
  end

  protected

  def after_sign_in_path_for(resource)
    @saved_guest_chat ? chat_path(@saved_guest_chat) : super
  end

  # DELETE /resource/sign_out
  # def destroy
  #   super
  # end

  # protected

  # If you have extra params to permit, append them to the sanitizer.
  # def configure_sign_in_params
  #   devise_parameter_sanitizer.permit(:sign_in, keys: [:attribute])
  # end
end
