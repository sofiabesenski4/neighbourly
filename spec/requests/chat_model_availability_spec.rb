require "rails_helper"

RSpec.describe "Chat model availability", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "availability@example.com", password: "password123") }
  let(:default_model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:other_model) { RubyLLM::Model.new(id: "gpt-test", name: "OpenAI chat", provider: "openai") }

  before do
    sign_in user
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([default_model, other_model]))
    allow(RubyLLM.config).to receive(:default_model).and_return(default_model.id)
    allow(ChatResponseJob).to receive(:perform_later)
  end

  it "does not silently select another model when the default provider is unavailable" do
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)
    allow(RubyLLM.config).to receive(:openai_api_key).and_return("configured-for-test")

    get new_chat_path

    select = Nokogiri::HTML(response.body).at_css("#chat_model")
    expect(select.at_css("option[selected]")["value"]).to eq("")
    expect(select.at_css("option[selected]")["disabled"]).to be_present
    expect(select.css("option:not([disabled])").map { |option| option["value"] }).to eq([other_model.id])
    expect(response.body).to include("Choose an available model to continue.")
  end

  it "marks an unavailable current model instead of offering it as a working choice" do
    chat = user.chats.create!(model: default_model)
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)
    allow(RubyLLM.config).to receive(:openai_api_key).and_return("configured-for-test")

    get chat_path(chat)

    select = Nokogiri::HTML(response.body).at_css("#message_model")
    expect(select.at_css("option[selected]").text).to include("unavailable")
    expect(select.at_css("option[selected]")["value"]).to eq("")
    expect(select.at_css("option[selected]")["disabled"]).to be_present
    expect(select.css("option:not([disabled])").map { |option| option["value"] }).to eq([other_model.id])
  end

  it "explains when no chat model provider is configured" do
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)
    allow(RubyLLM.config).to receive(:openai_api_key).and_return(nil)

    get new_chat_path

    expect(response.body).to include("No models are available. Please contact the site administrator.")
    expect(Nokogiri::HTML(response.body).css("#chat_model option:not([disabled])")).to be_empty
  end

  it "rejects a new chat with an unavailable default before saving or calling a provider" do
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)

    expect {
      post chats_path, params: {chat: {prompt: "Find meals"}}
    }.not_to change(Chat, :count)

    expect(response).to redirect_to(new_chat_path)
    expect(flash[:alert]).to include("unavailable")
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "rejects an explicitly selected unavailable model before saving a new chat" do
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)

    expect {
      post chats_path, params: {chat: {prompt: "Find meals", model: default_model.id}}
    }.not_to change(Chat, :count)

    expect(response).to redirect_to(new_chat_path)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "rejects an unavailable current model when the message omits model selection" do
    chat = user.chats.create!(model: default_model)
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)

    post chat_messages_path(chat), params: {message: {content: "Find meals"}}

    expect(response).to redirect_to(chat_path(chat))
    expect(flash[:alert]).to include("no longer available")
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "rejects an explicitly selected unavailable current model" do
    chat = user.chats.create!(model: default_model)
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)

    post chat_messages_path(chat), params: {message: {content: "Find meals", model: default_model.id}}

    expect(response).to redirect_to(chat_path(chat))
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end
end
