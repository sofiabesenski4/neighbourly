require "rails_helper"

RSpec.describe "Conversation model selection", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "models@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:default_model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:alternate_model) { RubyLLM::Model.new(id: "claude-sonnet-4-5", name: "Claude Sonnet", provider: "anthropic") }

  before do
    sign_in user
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([default_model, alternate_model]))
    allow(ChatResponseJob).to receive(:perform_later)
  end

  it "captures the selected model and provider for the submitted message without retargeting queued work" do
    original_model = chat.model_id

    post chat_messages_path(chat), params: {message: {content: "Find food", model: alternate_model.id}}

    expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, "Find food", model: alternate_model.id, provider: "anthropic")
    expect(chat.reload.model_id).to eq(original_model)
  end

  it "keeps the selected model in the refreshed composer before the job runs" do
    post chat_messages_path(chat), params: {message: {content: "Find food", model: alternate_model.id}}, as: :turbo_stream

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("option[selected]")["value"]).to eq(alternate_model.id)
  end

  it "rejects unavailable models without enqueuing a provider call" do
    post chat_messages_path(chat), params: {message: {content: "Find food", model: "unregistered-model"}}

    expect(response).to redirect_to(chat_path(chat))
    expect(flash[:alert]).to include("no longer available")
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "does not allow model switching through another user's conversation" do
    other_user = User.create!(email: "other-model@example.com", password: "password123")
    private_chat = other_user.chats.create!

    post chat_messages_path(private_chat), params: {message: {content: "Find food", model: alternate_model.id}}

    expect(ChatResponseJob).not_to have_received(:perform_later)
  end
end
