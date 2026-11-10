class ChatResponsesController < ApplicationController
  include ChatAccess

  before_action :set_chat
  before_action :set_chat_response, except: :latest
  after_action :verify_authorized

  # Retrying spends the same API budget as sending another message.
  rate_limit to: 10, within: 1.minute,
    by: :chat_budget_key,
    with: -> { rate_limit_exceeded("You're sending messages faster than we can answer them. Please wait a moment.") },
    only: :retry_response, name: "burst", scope: "chat_replies"
  rate_limit to: 100, within: 1.hour,
    by: :chat_budget_key,
    with: -> { rate_limit_exceeded("You've sent a lot of messages in the past hour. Please try again later.") },
    only: :retry_response, name: "sustained", scope: "chat_replies"

  def retry_response
    case @chat_response.retry!(expected_token: params[:attempt_token].presence)
    when :queued
      respond_to do |format|
        format.turbo_stream { render_status }
        format.html { redirect_to conversation_path(@chat), status: :see_other }
      end
    when :unavailable
      message = if @chat.guest?
        "Chat is temporarily unavailable. Please try again later."
      else
        "The model used for this reply is unavailable. Choose an available model and send your question again."
      end
      render_error(message, :unprocessable_content)
    else
      render_error("Only the latest failed reply can be retried when no response is running.", :conflict)
    end
  end

  def stop
    unless @chat_response.cancel!(expected_token: params[:attempt_token].presence)
      render_error("This reply has changed. Please try again from the current conversation.", :conflict)
      return
    end
    respond_to do |format|
      format.turbo_stream { render_status }
      format.html { redirect_to conversation_path(@chat), status: :see_other }
    end
  end

  def latest
    ChatResponseRecovery.call(@chat)
    latest_response = @chat.latest_response
    boundary = Integer(params[:after_response_id], exception: false).to_i.clamp(0, latest_response&.id || 0)
    responses = @chat.chat_responses.where(id: boundary..).includes(:user_message,
      assistant_message: [:ruby_llm_usages, :ruby_llm_tool_calls, {rag_documents: :source}]).order(:id).to_a
    response.set_header("Cache-Control", "no-store")
    response.set_header("X-Chat-Response-Boundary", latest_response&.id.to_i.to_s)
    respond_to do |format|
      format.turbo_stream do
        render partial: "chat_responses/snapshot", formats: [:html], locals: {chat: @chat, response: latest_response, responses: responses}
      end
      format.html { redirect_to conversation_path(@chat) }
    end
  end

  private

  def set_chat
    @chat = find_chat(params[:chat_id])
    return unless @chat

    authorize @chat, (action_name == "latest") ? :show? : :update?
  end

  def set_chat_response
    @chat_response = @chat.chat_responses.find(params[:id])
  end

  def render_error(message, status)
    respond_to do |format|
      format.turbo_stream { render_status(status: status, error: message) }
      format.html do
        flash.now[:alert] = message
        @message = @chat.messages.build
        set_recent_chats
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
