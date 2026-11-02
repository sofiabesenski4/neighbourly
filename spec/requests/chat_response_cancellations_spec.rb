require "rails_helper"

RSpec.describe "Stopping a chat response", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "stop-request@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:record) { ChatResponse.enqueue!(chat: chat, content: "Find free meals", model: chat.model_id, provider: chat.provider) }

  before do
    sign_in user
    allow(ChatResponseJob).to receive(:perform_later).and_return(true)
    record
  end

  it "stops the saved queued reply and returns the current status" do
    post stop_chat_chat_response_path(chat, record), as: :turbo_stream

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Response stopped")
    expect(record.reload).to be_cancelled
  end

  it "shows acknowledgement while a running worker is stopping and tolerates repeated clicks" do
    record.claim!
    2.times { post stop_chat_chat_response_path(chat, record), as: :turbo_stream }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Stopping")
    expect(record.reload).to be_cancelling
  end

  it "supports HTML requests" do
    post stop_chat_chat_response_path(chat, record)

    expect(response).to redirect_to(chat_path(chat))
    expect(record.reload).to be_cancelled
  end

  it "does not allow another user to stop the reply" do
    sign_in User.create!(email: "stop-other@example.com", password: "password123")
    post stop_chat_chat_response_path(chat, record)

    expect(response).to redirect_to(root_path)
    expect(record.reload).to be_queued
  end

  it "does not resolve a response through another conversation" do
    post stop_chat_chat_response_path(user.chats.create!, record)

    expect(response).to have_http_status(:not_found)
    expect(record.reload).to be_queued
  end

  it "requires sign-in" do
    sign_out user
    post stop_chat_chat_response_path(chat, record)

    expect(response).to redirect_to(new_user_session_path)
    expect(record.reload).to be_queued
  end
end
