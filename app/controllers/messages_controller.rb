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
    only: :create, name: "burst"
  rate_limit to: 100, within: 1.hour,
    by: -> { current_user.id },
    with: -> { rate_limit_exceeded("You've sent a lot of messages in the past hour. Please try again later.") },
    only: :create, name: "sustained"

  def create
    authorize @chat, :update?
    content = params.dig(:message, :content)
    if content.present?
      ChatResponseJob.perform_later(@chat.id, content)

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to @chat }
      end
    end
  end

  private

  def set_chat
    @chat = Chat.find(params[:chat_id])
  end
end
