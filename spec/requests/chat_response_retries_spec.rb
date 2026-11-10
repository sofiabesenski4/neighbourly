require "rails_helper"

RSpec.describe "Chat response retries", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "retry-request@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:response_record) { ChatResponse.enqueue!(chat: chat, content: "Find free meals", model: chat.model_id, provider: chat.provider) }

  before do
    sign_in user
    response_record.fail!
    clear_enqueued_jobs
  end

  it "retries the failed reply with its saved model without duplicating the question" do
    expect {
      post retry_chat_chat_response_path(chat, response_record), as: :turbo_stream
    }.not_to change(Message, :count)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Getting ready")
    expect(response_record.reload).to be_queued
    expect(ChatResponseJob).to have_been_enqueued.with(chat.id, "Find free meals",
      model: response_record.model_id, provider: response_record.provider, response_id: response_record.id, attempt_token: response_record.attempt_token).once
  end

  it "keeps the failed reply's retry control after refreshing the conversation" do
    get chat_path(chat)

    expect(response.body).to include(retry_chat_chat_response_path(chat, response_record), "Retry reply", "Find free meals")
  end

  it "returns a conflict for a repeated click without enqueueing twice" do
    2.times { post retry_chat_chat_response_path(chat, response_record), as: :turbo_stream }

    expect(response).to have_http_status(:conflict)
    expect(response.body).to include("Only the latest failed reply", "Getting ready")
    expect(ChatResponseJob).to have_been_enqueued.exactly(:once)
  end

  it "returns a safe error without removing a failed reply when its model is unavailable" do
    availability = instance_double(ChatModelAvailability, find: nil)
    allow(ChatModelAvailability).to receive(:new).and_return(availability)

    post retry_chat_chat_response_path(chat, response_record), as: :turbo_stream

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("model used for this reply is unavailable", "Retry reply")
    expect(response_record.reload).to be_failed
    expect(enqueued_jobs).to be_empty
  end

  it "renders a safe HTML conflict for a stale retry" do
    response_record.update!(status: "completed")

    post retry_chat_chat_response_path(chat, response_record)

    expect(response).to have_http_status(:conflict)
    expect(response.body).to include("Only the latest failed reply")
    expect(enqueued_jobs).to be_empty
  end

  it "does not allow another user to retry the reply" do
    sign_in User.create!(email: "retry-other@example.com", password: "password123")

    post retry_chat_chat_response_path(chat, response_record)

    expect(response).to redirect_to(root_path)
    expect(response_record.reload).to be_failed
    expect(enqueued_jobs).to be_empty
  end

  it "does not resolve a response through a different conversation" do
    another_chat = user.chats.create!

    post retry_chat_chat_response_path(another_chat, response_record)

    expect(response).to have_http_status(:not_found)
    expect(enqueued_jobs).to be_empty
  end

  it "requires sign-in" do
    sign_out user

    post retry_chat_chat_response_path(chat, response_record)

    expect(response).to redirect_to(new_user_session_path)
    expect(enqueued_jobs).to be_empty
  end

  it "counts retries against the normal message burst budget" do
    10.times do
      post retry_chat_chat_response_path(chat, response_record)
      response_record.reload.fail!
    end

    expect {
      post chat_messages_path(chat), params: {message: {content: "Another question"}}
    }.not_to change(Message, :count)

    expect(flash[:alert]).to include("faster than we can answer")
    expect(ChatResponseJob).to have_been_enqueued.exactly(10).times
  end

  it "counts normal messages against the retry burst budget" do
    10.times do
      post chat_messages_path(chat), params: {message: {content: "Another question"}}
      chat.chat_responses.last.fail!
    end

    post retry_chat_chat_response_path(chat, chat.chat_responses.last)

    expect(flash[:alert]).to include("faster than we can answer")
    expect(ChatResponseJob).to have_been_enqueued.exactly(10).times
    expect(chat.chat_responses.last).to be_failed
  end
end
