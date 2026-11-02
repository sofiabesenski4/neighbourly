require "rails_helper"

RSpec.describe "Chat response progress", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "progress@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  before do
    sign_in user
    allow(ChatResponseJob).to receive(:perform_later)
  end

  it "saves the first question before its background job starts" do
    post chats_path, params: {chat: {prompt: "Find meals in Victoria"}}

    created_chat = user.chats.last
    response_record = created_chat.chat_responses.last
    expect(response_record).to be_queued
    expect(response_record.user_message.content).to eq("Find meals in Victoria")
    expect(created_chat.messages.where(role: "user").count).to eq(1)
    expect(ChatResponseJob).to have_received(:perform_later).with(created_chat.id, "Find meals in Victoria", hash_including(response_id: response_record.id))
  end

  it "persists a follow-up question immediately and captures its model" do
    post chat_messages_path(chat), params: {message: {content: "What is open today?"}}

    response_record = chat.chat_responses.last
    expect(response_record.user_message.content).to eq("What is open today?")
    expect(response_record.model_id).to eq(chat.model_id)
    expect(response_record.provider).to eq(chat.provider.to_s)
  end

  it "rejects a second in-flight request without saving a duplicate and keeps its draft" do
    post chat_messages_path(chat), params: {message: {content: "First question"}}

    expect {
      post chat_messages_path(chat), params: {message: {content: "An unsent second question"}}, as: :turbo_stream
    }.not_to change(Message.where(chat_id: chat.id, role: "user"), :count)

    expect(response).to have_http_status(:conflict)
    expect(response.body).to include("An unsent second question", "already")
    expect(chat.chat_responses.count).to eq(1)
    expect(ChatResponseJob).to have_received(:perform_later).once
  end

  it "shows persistent progress and failure after a page refresh" do
    post chat_messages_path(chat), params: {message: {content: "Find meals"}}
    record = chat.chat_responses.last
    record.update!(status: "searching")
    get chat_path(chat)
    expect(response.body).to include("Finding local resources")

    record.update!(status: "failed", error_message: "The reply could not be completed. Your question is saved.")
    get chat_path(chat)
    expect(response.body).to include("Your question is saved.", "Find meals")
  end
end
