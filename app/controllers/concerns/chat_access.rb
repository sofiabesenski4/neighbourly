module ChatAccess
  extend ActiveSupport::Concern

  included do
    before_action :prevent_guest_chat_caching
    helper_method :conversation_path
  end

  private

  def guest_chat_session
    @guest_chat_session ||= GuestChatSession.new(request.headers[GuestChatSession::HEADER])
  end

  def pundit_user
    current_user || guest_chat_session
  end

  def find_chat(id)
    return Chat.find(id) if user_signed_in?

    chat = policy_scope(Chat).find_by(id: id)
    return chat if chat
    return authenticate_user! unless guest_chat_session.started? || request.path_parameters[:guest_entry]

    redirect_to new_chat_path, alert: "This conversation is no longer available in this tab.", status: :see_other
    nil
  end

  def conversation_path(chat)
    chat.guest? ? guest_chat_path(chat) : chat_path(chat)
  end

  def prevent_guest_chat_caching
    response.set_header("Cache-Control", "no-store") unless user_signed_in?
  end

  def set_recent_chats
    chats = user_signed_in? ? current_user.chats : policy_scope(Chat).limit(30)
    @recent_chats = chats.order(created_at: :desc, id: :desc).includes(:first_user_message)
  end

  def chat_budget_key
    user_signed_in? ? current_user.id : "guest:#{request.remote_ip}"
  end
end
