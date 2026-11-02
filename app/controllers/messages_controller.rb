class MessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_chat
  after_action :verify_authorized

  # Each message enqueues a ChatResponseJob, so this is the hottest path to our
  # API keys. The burst limit leaves room for normal back-and-forth typing while
  # the sustained limit caps what a script can spend in an hour.
  rate_limit to: 10, within: 1.minute,
    by: -> { current_user.id },
    with: -> { rate_limit_exceeded("You're sending messages faster than we can answer them. Please wait a moment.") },
    only: :create, name: "burst", scope: "chat_replies"
  rate_limit to: 100, within: 1.hour,
    by: -> { current_user.id },
    with: -> { rate_limit_exceeded("You've sent a lot of messages in the past hour. Please try again later.") },
    only: :create, name: "sustained", scope: "chat_replies"

  def create
    authorize @chat, :update?
    content = params.dig(:message, :content)
    if content.present?
      requested_model = params.dig(:message, :model).presence
      selection = requested_model || @chat.model_id
      provider = @chat.provider if requested_model.blank? || requested_model == @chat.model_id
      selected_model = ChatModelAvailability.new.find(selection, provider: provider)
      unless selected_model
        redirect_to @chat, alert: "That model is no longer available. Please choose another model.", status: :see_other
        return
      end
      @selected_model = selected_model.id
      @chat_response = ChatResponse.enqueue!(chat: @chat, content: content, model: selected_model.id, provider: selected_model.provider)
      @user_message = @chat_response.user_message

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to @chat }
      end
    end
  rescue ChatResponse::Busy => error
    @message = @chat.messages.build(content: content)
    @message.errors.add(:base, error.message)
    respond_to do |format|
      format.turbo_stream { render :create, status: :conflict }
      format.html do
        @recent_chats = current_user.chats.order(created_at: :desc, id: :desc).limit(30).includes(:first_user_message)
        render "chats/show", status: :conflict
      end
    end
  end

  private

  def set_chat
    @chat = Chat.find(params[:chat_id])
  end
end
