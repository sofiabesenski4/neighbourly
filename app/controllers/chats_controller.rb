class ChatsController < ApplicationController
  include ChatAccess

  before_action :prepare_landing_question, only: :create, if: :landing_question_request?
  before_action :set_chat, only: [:show, :destroy]
  before_action :set_recent_chats, only: [:new, :show]
  after_action :verify_authorized

  # Account limits are per user. Guest limits are per IP so opening a new
  # tab does not reset the budget for starting chats.
  rate_limit to: 5, within: 1.minute,
    by: :chat_budget_key,
    with: -> { chat_start_limit_exceeded("You're starting new chats too quickly. Please wait a moment and try again.") },
    only: :create, name: "burst"
  rate_limit to: 30, within: 1.hour,
    by: :chat_budget_key,
    with: -> { chat_start_limit_exceeded("You've started a lot of chats in the past hour. Please try again later.") },
    only: :create, name: "sustained"

  def new
    @chat = Chat.new
    authorize @chat
    @selected_model = params[:model]
    @chat_models = available_chat_models if user_signed_in?
  end

  def create
    @chat = if user_signed_in?
      current_user.chats.build
    else
      Chat.new(guest_session_digest: guest_chat_session.digest)
    end
    authorize @chat

    prompt = landing_question_request? ? @landing_question.prompt : submitted_prompt
    unless user_signed_in? || guest_chat_session.started?
      message = "Enable JavaScript and reopen Chat to start a guest conversation."
      return render_landing_error(message, status: :unprocessable_content) if landing_question_request?

      return render_guest_start_error(prompt, message, :unprocessable_content)
    end
    if @chat.guest? && !landing_question_request?
      question = LandingQuestion.new(prompt: prompt)
      unless question.valid?
        return render_guest_start_error(prompt, question.errors[:prompt].first, :unprocessable_content)
      end
    end

    model_id = RubyLLM.config.default_model
    if user_signed_in? && !landing_question_request?
      model_id = params.dig(:chat, :model).presence || model_id
    end
    selected_model = ChatModelAvailability.new.find(model_id)
    unless selected_model
      if landing_question_request?
        render_landing_error("Chat is temporarily unavailable. Please try again later.", status: :service_unavailable)
      elsif @chat.guest?
        render_guest_start_error(prompt, "Chat is temporarily unavailable. Please try again later.", :service_unavailable)
      else
        redirect_to new_chat_path, alert: "That model is unavailable. Please choose an available model.", status: :see_other
      end
      return
    end
    @chat.model = selected_model

    if prompt.present?
      Chat.transaction do
        @chat.save!
        ChatResponse.enqueue!(chat: @chat, content: prompt, model: selected_model.id, provider: selected_model.provider)
      end

      LandingQuestion.forget(session.delete(:landing_question_token)) if landing_question_request?
      redirect_to conversation_path(@chat), notice: "Chat was successfully created.", status: :see_other
    end
  rescue ActiveRecord::RecordInvalid
    message = "We couldn't start your chat. Please try again."
    if landing_question_request?
      render_landing_error(message, status: :unprocessable_content)
    elsif @chat.guest?
      render_guest_start_error(prompt, message, :unprocessable_content)
    else
      raise
    end
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
          format.html do
            redirect_to @current_chat ? conversation_path(@current_chat) : new_chat_path,
              notice: "Chat was successfully destroyed.", status: :see_other
          end
        end
      else
        redirect_to new_chat_path, notice: "Chat was successfully destroyed.", status: :see_other
      end
    else
      redirect_to new_chat_path, notice: "Chat was successfully destroyed.", status: :see_other
    end
  end

  private

  def landing_question_request?
    params[:entrypoint] == "landing"
  end

  def prepare_landing_question
    @landing_question = LandingQuestion.new(prompt: submitted_prompt)
    unless @landing_question.valid?
      render "pages/home", status: :unprocessable_content
      return
    end
    return unless user_signed_in?

    token = @landing_question.remember(session[:landing_question_token])
    unless token
      render_landing_error("We couldn't keep your question. Please try again.", status: :service_unavailable)
      return
    end

    session[:landing_question_token] = token
  end

  def submitted_prompt
    input = params[:chat]
    prompt = input[:prompt] if input.is_a?(ActionController::Parameters)
    prompt if prompt.is_a?(String)
  end

  def render_landing_error(message, status:)
    @landing_question.errors.add(:base, message)
    render "pages/home", status: status
  end

  def render_guest_start_error(prompt, message, status)
    @guest_prompt = prompt
    @chat.errors.add(:base, message)
    set_recent_chats
    render :new, status: status
  end

  def chat_start_limit_exceeded(message)
    return rate_limit_exceeded(message) if user_signed_in?
    return render_landing_error(message, status: :too_many_requests) if landing_question_request?

    @chat = Chat.new
    render_guest_start_error(submitted_prompt, message, :too_many_requests)
  end

  def set_chat
    @chat = find_chat(params[:id])
  end
end
