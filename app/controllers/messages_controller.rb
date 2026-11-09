class MessagesController < ApplicationController
  include ChatAccess

  before_action :set_chat
  after_action :verify_authorized

  # Each message enqueues a ChatResponseJob, so this is the hottest path to our
  # API keys. The burst limit leaves room for normal back-and-forth typing while
  # the sustained limit caps what a script can spend in an hour.
  rate_limit to: 10, within: 1.minute,
    by: :chat_budget_key,
    with: -> { rate_limit_exceeded("You're sending messages faster than we can answer them. Please wait a moment.") },
    only: :create, name: "burst", scope: "chat_replies"
  rate_limit to: 100, within: 1.hour,
    by: :chat_budget_key,
    with: -> { rate_limit_exceeded("You've sent a lot of messages in the past hour. Please try again later.") },
    only: :create, name: "sustained", scope: "chat_replies"

  def create
    authorize @chat, :update?
    input = params[:message]
    content = input[:content] if input.is_a?(ActionController::Parameters)
    if @chat.guest? && (!content.is_a?(String) || content.blank? || content.length > LandingQuestion::MAX_LENGTH)
      redirect_to conversation_path(@chat), alert: "Enter a message of up to 2,000 characters.", status: :see_other
      return
    end
    if content.present?
      requested_model = input[:model].presence unless @chat.guest?
      selection = requested_model || @chat.model_id
      provider = @chat.provider if requested_model.blank? || requested_model == @chat.model_id
      selected_model = ChatModelAvailability.new.find(selection, provider: provider)
      unless selected_model
        alert = if @chat.guest?
          "Chat is temporarily unavailable. Please try again later."
        else
          "That model is no longer available. Please choose another model."
        end
        redirect_to conversation_path(@chat), alert: alert, status: :see_other
        return
      end
      @selected_model = selected_model.id
      @chat_response = ChatResponse.enqueue!(chat: @chat, content: content, model: selected_model.id, provider: selected_model.provider)
      @user_message = @chat_response.user_message

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to conversation_path(@chat) }
      end
    end
  rescue ChatResponse::Busy => error
    @message = @chat.messages.build(content: content)
    @message.errors.add(:base, error.message)
    respond_to do |format|
      format.turbo_stream { render :create, status: :conflict }
      format.html do
        set_recent_chats
        render "chats/show", status: :conflict
      end
    end
  end

  private

  def set_chat
    @chat = find_chat(params[:chat_id])
  end
end
