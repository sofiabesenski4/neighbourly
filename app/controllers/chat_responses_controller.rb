class ChatResponsesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_chat_response
  after_action :verify_authorized

  # Retrying spends the same API budget as sending another message.
  rate_limit to: 10, within: 1.minute,
    by: -> { current_user.id },
    with: -> { rate_limit_exceeded("You're sending messages faster than we can answer them. Please wait a moment.") },
    only: :retry_response, name: "burst", scope: "chat_replies"
  rate_limit to: 100, within: 1.hour,
    by: -> { current_user.id },
    with: -> { rate_limit_exceeded("You've sent a lot of messages in the past hour. Please try again later.") },
    only: :retry_response, name: "sustained", scope: "chat_replies"

  def retry_response
    case @chat_response.retry!
    when :queued
      respond_to do |format|
        format.turbo_stream { render_status }
        format.html { redirect_to @chat, status: :see_other }
      end
    when :unavailable
      render_error("The model used for this reply is unavailable. Choose an available model and send your question again.", :unprocessable_content)
    else
      render_error("Only the latest failed reply can be retried when no response is running.", :conflict)
    end
  end

  private

  def set_chat_response
    @chat = Chat.find(params[:chat_id])
    authorize @chat, :update?
    @chat_response = @chat.chat_responses.find(params[:id])
  end

  def render_error(message, status)
    respond_to do |format|
      format.turbo_stream { render_status(status: status, error: message) }
      format.html do
        flash.now[:alert] = message
        @message = @chat.messages.build
        @recent_chats = current_user.chats.order(created_at: :desc, id: :desc).limit(30).includes(:first_user_message)
        render "chats/show", status: status
      end
    end
  end

  def render_status(status: :ok, error: nil)
    render turbo_stream: turbo_stream.replace("chat_#{@chat.id}_response_status",
      partial: "chats/response_status",
      locals: {chat: @chat, response: @chat.latest_response, retry_error: error}), status: status
  end
end
