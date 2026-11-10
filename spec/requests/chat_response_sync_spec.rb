require "rails_helper"

RSpec.describe "Chat response reconciliation", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "response-sync-request@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Meals") }
  let!(:record) { ChatResponse.enqueue!(chat: chat, content: "Find food", model: chat.model_id, provider: chat.provider) }

  before { sign_in user }

  it "echoes the saved follow-up and current progress in the HTTP response" do
    another_chat = user.chats.create!

    post chat_messages_path(another_chat), params: {message: {content: "Find a community meal"}}, as: :turbo_stream

    expect(response).to have_http_status(:ok)
    saved = another_chat.chat_responses.last
    expect(response.body).to include("message_#{saved.user_message_id}", "Find a community meal", "Getting ready", "data-response-version")
  end

  it "returns only the latest question and terminal visible answer without creating records" do
    chat.messages.create!(role: "system", content: "Private retrieval instructions")
    answer = chat.messages.create!(role: "assistant", content: "Try a community kitchen")
    record.update!(assistant_message: answer, status: "completed")

    expect {
      get latest_chat_chat_responses_path(chat), as: :turbo_stream
    }.not_to change(ChatResponse, :count)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Find food", "Try a community kitchen", "data-response-version")
    expect(response.body).not_to include("Private retrieval instructions")
  end

  it "does not send persisted assistant placeholders while streaming" do
    answer = chat.messages.create!(role: "assistant", content: "")
    record.update!(assistant_message: answer, status: "writing")

    get latest_chat_chat_responses_path(chat), as: :turbo_stream

    expect(response.body).to include("Find food", "Writing a response")
    expect(response.body).not_to include("id=\"message_#{answer.id}\"")
  end

  it "does not expose another user's conversation" do
    sign_in User.create!(email: "response-sync-other@example.com", password: "password123")

    get latest_chat_chat_responses_path(chat), as: :turbo_stream

    expect(response).to redirect_to(root_path)
    expect(response.body).not_to include("Find food")
  end

  it "requires sign-in" do
    sign_out user

    get latest_chat_chat_responses_path(chat), as: :turbo_stream

    expect(response).to redirect_to(new_user_session_path)
  end

  it "repairs missed completed pairs and uses an inclusive HTTP reconciliation boundary" do
    first_answer = chat.messages.create!(role: "assistant", content: "First answer")
    record.update!(assistant_message: first_answer, status: "completed")
    second = ChatResponse.enqueue!(chat: chat, content: "Second question", model: chat.model_id, provider: chat.provider)
    second_answer = chat.messages.create!(role: "assistant", content: "Second answer")
    second.update!(assistant_message: second_answer, status: "completed")

    get latest_chat_chat_responses_path(chat), as: :turbo_stream

    expect(response.body).to include("Find food", "First answer", "Second question", "Second answer")
    expect(response.headers["X-Chat-Response-Boundary"]).to eq(second.id.to_s)

    get latest_chat_chat_responses_path(chat), params: {after_response_id: second.id}, as: :turbo_stream

    expect(response.body).to include("Second question", "Second answer")
    expect(response.body).not_to include("First answer")
  end
end
