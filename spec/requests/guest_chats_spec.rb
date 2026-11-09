require "rails_helper"

RSpec.describe "Guest chats", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:question) { "Where can I get a free meal?" }
  let(:tab_key) { SecureRandom.hex(32) }
  let(:tab_headers) { {"X-Neighbourly-Guest-Token" => tab_key} }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
    allow(RubyLLM.config).to receive(:default_model).and_return(model.id)
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
    allow(ChatResponseJob).to receive(:perform_later)
  end

  def start_guest_chat(headers: tab_headers)
    post start_chat_path, params: {chat: {prompt: question, model: "untrusted-model"}}, headers: headers
    expect(response.location).to match(%r{/guest-chats/\d+\z})
    Chat.last
  end

  it "saves all active conversations from the originating tab after successful sign-in" do
    chat = start_guest_chat
    other_chat = start_guest_chat
    different_tab_chat = start_guest_chat(headers: {"X-Neighbourly-Guest-Token" => SecureRandom.hex(32)})
    user = User.create!(email: "save-guest@example.com", password: "password123")
    headers = tab_headers.merge("X-Neighbourly-Guest-Chat" => chat.id.to_s)
    guest_stream = "chat_#{chat.id}"

    post user_session_path, params: {user: {email: user.email, password: "wrong-password"}}, headers: headers
    expect(chat.reload).to be_guest
    expect(other_chat.reload).to be_guest

    expect {
      post user_session_path, params: {user: {email: user.email, password: "password123"}}, headers: headers
    }.not_to change(Chat, :count)
    expect(response).to redirect_to(chat_path(chat))
    expect(chat.reload.user).to eq(user)
    expect(chat.guest_session_digest).to be_nil
    expect(chat.stream_name).not_to eq(guest_stream)
    expect(other_chat.reload.user).to eq(user)
    expect(other_chat.guest_session_digest).to be_nil
    expect(different_tab_chat.reload).to be_guest
    follow_redirect!
    expect(response.body).to include(question)

    other_browser = open_session
    other_browser.get guest_chat_path(chat), headers: tab_headers
    expect(URI.parse(other_browser.response.location).path).to eq(new_chat_path)
    allow(ActionCable.server).to receive(:broadcast).and_call_original
    chat.messages.create!(role: "user", content: "Private account follow-up")
    expect(ActionCable.server).to have_received(:broadcast).with(chat.stream_name, any_args)
    expect(ActionCable.server).not_to have_received(:broadcast).with(guest_stream, any_args)
  end

  it "does not save a guest conversation without the originating tab key" do
    chat = start_guest_chat
    user = User.create!(email: "wrong-tab@example.com", password: "password123")
    headers = {"X-Neighbourly-Guest-Chat" => chat.id.to_s, "X-Neighbourly-Guest-Token" => SecureRandom.hex(32)}

    post user_session_path, params: {user: {email: user.email, password: "password123"}}, headers: headers

    expect(response).to redirect_to(root_path)
    expect(chat.reload).to be_guest
  end

  it "does not save an expired guest conversation even with the correct tab key" do
    chat = start_guest_chat
    user = User.create!(email: "expired-guest@example.com", password: "password123")

    travel 25.hours do
      post user_session_path, params: {user: {email: user.email, password: "password123"}},
        headers: tab_headers.merge("X-Neighbourly-Guest-Chat" => chat.id.to_s)

      expect(response).to redirect_to(root_path)
      expect(chat.reload).to be_guest
    end
  end

  it "opens the chat workspace without creating a chat or running a model" do
    expect { get new_chat_path }.not_to change(Chat, :count)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("New conversation")
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "keeps a question editable when the guest workspace cannot start a chat" do
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)

    expect { post chats_path, params: {chat: {prompt: question}}, headers: tab_headers }.not_to change(Chat, :count)

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("Chat is temporarily unavailable")
    expect(Nokogiri::HTML5(response.body).at_css("textarea").text).to eq(question)
  end

  it "requires a tab key to start a guest chat" do
    expect { post start_chat_path, params: {chat: {prompt: question}} }.not_to change(Chat, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "starts a chat without an account and requires the tab key even with the original cookies" do
    user_count = User.count
    chat = nil
    expect { chat = start_guest_chat }.to change(ChatResponse, :count).by(1)
    expect(User.count).to eq(user_count)
    expect(chat.user).to be_nil
    expect(chat.model_id).to eq(model.id)
    expect(response.location).not_to include(question, tab_key)
    expect(request.session.to_hash.values).not_to include(question, tab_key)
    expect(request.session[:guest_chat_token]).to be_nil

    get guest_chat_path(chat), headers: tab_headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).to include(question)

    get guest_chat_path(chat)
    expect(response).to redirect_to(new_chat_path)
    follow_redirect!
    expect(response.body).not_to include(question)
  end

  it "allows follow-ups, reply updates, retry, stop and delete from the originating browser" do
    chat = start_guest_chat
    reply = chat.latest_response
    reply.update!(status: :failed)

    post retry_chat_chat_response_path(chat, reply), params: {attempt_token: reply.attempt_token}, headers: tab_headers
    expect(response).to redirect_to(guest_chat_path(chat))
    expect(reply.reload).to be_queued

    post stop_chat_chat_response_path(chat, reply), params: {attempt_token: reply.attempt_token}, headers: tab_headers
    expect(response).to redirect_to(guest_chat_path(chat))
    expect(reply.reload).to be_cancelled

    expect {
      post chat_messages_path(chat), params: {message: {content: "Any options downtown?", model: "untrusted-model"}}, headers: tab_headers
    }.to change(ChatResponse, :count).by(1)
    get latest_chat_chat_responses_path(chat), as: :turbo_stream, headers: tab_headers
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Any options downtown?")

    expect { delete chat_path(chat), params: {from: "workspace"}, headers: tab_headers }.to change(Chat, :count).by(-1)
    expect(response).to redirect_to(new_chat_path)
  end

  it "denies the same chat and its reply operations to another browser" do
    chat = start_guest_chat
    other_browser = open_session
    reply = chat.latest_response

    other_browser.get guest_chat_path(chat), headers: {"X-Neighbourly-Guest-Token" => SecureRandom.hex(32)}
    expect(URI.parse(other_browser.response.location).path).to eq(new_chat_path)
    other_browser.get latest_chat_chat_responses_path(chat), as: :turbo_stream
    expect(URI.parse(other_browser.response.location).path).to eq(new_user_session_path)
    expect(other_browser.response.body).not_to include(question)

    expect {
      other_browser.post chat_messages_path(chat), params: {message: {content: "Injected question"}}
      other_browser.post stop_chat_chat_response_path(chat, reply), params: {attempt_token: reply.attempt_token}
      other_browser.delete chat_path(chat)
    }.not_to change(ChatResponse, :count)
    expect(reply.reload).to be_queued
    expect(Chat.exists?(chat.id)).to be(true)
  end

  it "limits guest starts across sessions from the same IP" do
    5.times do
      open_session.post start_chat_path, params: {chat: {prompt: question}}, headers: {"X-Neighbourly-Guest-Token" => SecureRandom.hex(32)}
    end
    sixth_browser = open_session
    expect {
      sixth_browser.post start_chat_path, params: {chat: {prompt: question}}, headers: {"X-Neighbourly-Guest-Token" => SecureRandom.hex(32)}
    }.not_to change(Chat, :count)
    expect(sixth_browser.response.status).to eq(429)
    expect(sixth_browser.response.body).to include("starting new chats too quickly")
    expect(ChatResponseJob).to have_received(:perform_later).exactly(5).times
  end

  it "keeps account-owned chats and guest chats in separate access scopes" do
    chat = start_guest_chat
    admin = User.create!(email: "guest-chat-admin@example.com", password: "password123", admin: true)
    account_chat = admin.chats.create!

    get chat_path(account_chat), headers: tab_headers
    expect(response).to redirect_to(new_chat_path)

    sign_in admin
    get new_chat_path
    expect(response.body).to include(chat_path(account_chat))
    expect(response.body).not_to include(guest_chat_path(chat), question)
    get guest_chat_path(chat), headers: tab_headers
    expect(response).to redirect_to(root_path)
  end

  it "expires guest access and removes expired chats with their messages" do
    chat = start_guest_chat
    message = chat.latest_response.user_message
    account = User.create!(email: "guest-cleanup-account@example.com", password: "password123")
    account_chat = account.chats.create!

    travel 25.hours do
      get guest_chat_path(chat), headers: tab_headers
      expect(response).to redirect_to(new_chat_path)
      follow_redirect!
      expect(response.body).to include("This conversation is no longer available in this tab.")

      ExpireGuestChatsJob.perform_now
      expect(Chat.exists?(chat.id)).to be(false)
      expect(Message.exists?(message.id)).to be(false)
      expect(Chat.exists?(account_chat.id)).to be(true)
    end
  end
end
