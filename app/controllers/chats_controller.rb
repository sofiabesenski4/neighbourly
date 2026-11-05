class ChatsController < ApplicationController
  before_action :prepare_landing_question, only: :create, if: :landing_question_request?
  before_action :authenticate_user!
  before_action :set_chat, only: [:show, :destroy]
  before_action :set_recent_chats, only: [:new, :show]
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
    @chat = current_user.chats.build
    authorize @chat

    model_id = landing_question_request? ? RubyLLM.config.default_model : params.dig(:chat, :model).presence || RubyLLM.config.default_model
    selected_model = ChatModelAvailability.new.find(model_id)
    unless selected_model
      if landing_question_request?
        render_landing_error("Chat is temporarily unavailable. Please try again later.", status: :service_unavailable)
      else
        redirect_to new_chat_path, alert: "That model is unavailable. Please choose an available model.", status: :see_other
      end
      return
    end
    @chat.model = selected_model

    prompt = landing_question_request? ? @landing_question.prompt : params.dig(:chat, :prompt)
    if prompt.present?
      Chat.transaction do
        @chat.save!
        ChatResponse.enqueue!(chat: @chat, content: prompt, model: selected_model.id, provider: selected_model.provider)
      end

      LandingQuestion.forget(session.delete(:landing_question_token)) if landing_question_request?
      redirect_to @chat, notice: "Chat was successfully created."
    end
  rescue ActiveRecord::RecordInvalid
    raise unless landing_question_request?

    render_landing_error("We couldn't start your chat. Please try again.", status: :unprocessable_content)
  end

  def show
    authorize @chat
    ChatResponseRecovery.call(@chat)
    @message = @chat.messages.build
  end

  def destroy
    authorize @chat
    @chat.destroy!

    if params[:from] == "workspace"
      @current_chat = policy_scope(Chat).find_by(id: params[:current_chat_id])
      if @current_chat || params[:current_chat_id].blank?
        respond_to do |format|
          format.turbo_stream
          format.html { redirect_to @current_chat || new_chat_path, notice: "Chat was successfully destroyed.", status: :see_other }
        end
      else
        redirect_to new_chat_path, notice: "Chat was successfully destroyed.", status: :see_other
      end
    else
      redirect_to chats_path, notice: "Chat was successfully destroyed.", status: :see_other
    end
  end

  private

  def landing_question_request?
    params[:entrypoint] == "landing"
  end

  def prepare_landing_question
    input = params[:chat]
    prompt = input[:prompt] if input.is_a?(ActionController::Parameters)
    @landing_question = LandingQuestion.new(prompt: prompt.is_a?(String) ? prompt : nil)
    unless @landing_question.valid?
      render "pages/home", status: :unprocessable_content
      return
    end

    token = @landing_question.remember(session[:landing_question_token])
    unless token
      render_landing_error("We couldn't keep your question while you sign in. Please try again.", status: :service_unavailable)
      return
    end

    session[:landing_question_token] = token
    store_location_for(:user, root_path) unless user_signed_in?
  end

  def render_landing_error(message, status:)
    @landing_question.errors.add(:base, message)
    render "pages/home", status: status
  end

  def set_recent_chats
    @recent_chats = current_user.chats.order(created_at: :desc, id: :desc).limit(30).includes(:first_user_message)
  end

  def set_chat
    @chat = Chat.find(params[:id])
  end
end
