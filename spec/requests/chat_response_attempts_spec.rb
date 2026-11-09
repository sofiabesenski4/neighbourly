require "rails_helper"

RSpec.describe "Recovering interrupted reply attempts", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "attempt-request@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:record) { ChatResponse.enqueue!(chat: chat, content: "Find meals", model: chat.model_id, provider: chat.provider) }

  before do
    sign_in user
    allow(ChatResponseJob).to receive(:perform_later)
  end

  it "does not let a delayed Stop cancel a newer retry attempt" do
    old_token = record.attempt_token
    record.fail!
    record.retry!

    post stop_chat_chat_response_path(chat, record), params: {attempt_token: old_token}, as: :turbo_stream

    expect(response).to have_http_status(:conflict)
    expect(record.reload).to be_queued
    expect(response.body).to include("reply has changed")
  end

  it "does not retry a second failed attempt with the first attempt's stale control" do
    old_token = record.attempt_token
    record.fail!
    record.retry!
    record.fail!

    post retry_chat_chat_response_path(chat, record), params: {attempt_token: old_token}, as: :turbo_stream

    expect(response).to have_http_status(:conflict)
    expect(record.reload).to be_failed
    expect(ChatResponseJob).to have_received(:perform_later).twice
  end

  it "recovers a lost queued job when the live status is refreshed" do
    record.update!(heartbeat_at: 3.minutes.ago)

    get latest_chat_chat_responses_path(chat), as: :turbo_stream

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("start in time", "Retry reply", "Find meals")
    expect(record.reload).to be_failed
  end

  it "allows a fresh question after recovering an expired queued reply" do
    record.update!(heartbeat_at: 3.minutes.ago)

    post chat_messages_path(chat), params: {message: {content: "What is open now?"}}

    expect(response).to redirect_to(chat_path(chat))
    expect(record.reload).to be_failed
    expect(chat.chat_responses.last).to be_queued
    expect(chat.messages.where(role: "user").order(:id).pluck(:content)).to eq(["Find meals", "What is open now?"])
  end
end
