class ChatsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_chat, only: [:show, :destroy]
  after_action :verify_authorized, except: :index

  # Every chat created fires an LLM call billed to our API keys. Declared after
  # authenticate_user! so current_user is always present here, and keyed on the
  # user rather than the IP so a shared connection is not one shared budget.
  rate_limit to: 5, within: 1.minute,
    by: -> { current_user.id },
    with: -> { rate_limit_exceeded("You're starting new chats too quickly. Please wait a moment and try again.") },
    only: :create, name: "burst"
  rate_limit to: 30, within: 1.hour,
    by: -> { current_user.id },
    with: -> { rate_limit_exceeded("You've started a lot of chats in the past hour. Please try again later.") },
    only: :create, name: "sustained"

  def index
    @chats = policy_scope(Chat).order(created_at: :desc)
  end

  def new
    @chat = Chat.new
    authorize @chat
    @selected_model = params[:model]
    @chat_models = available_chat_models
  end

  def create
    @chat = current_user.chats.build(
      model: params.dig(:chat, :model).presence,
      use_rag: params.dig(:chat, :use_rag) == "1"
    )
    authorize @chat

    prompt = params.dig(:chat, :prompt)
    if prompt.present?
      @chat.save!
      ChatResponseJob.perform_later(@chat.id, prompt)

      redirect_to @chat, notice: "Chat was successfully created."
    end
  end

  def show
    authorize @chat
    @message = @chat.messages.build
  end

  def destroy
    authorize @chat
    @chat.destroy!
    redirect_to chats_path, notice: "Chat was successfully destroyed.", status: :see_other
  end

  private

  def set_chat
    @chat = Chat.find(params[:id])
  end
end
