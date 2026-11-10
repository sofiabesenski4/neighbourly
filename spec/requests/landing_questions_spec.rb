require "rails_helper"

RSpec.describe "Landing questions", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "landing-question@example.com", password: "password123") }
  let(:question) { "Where can I get a free meal?\nSomewhere downtown today." }
  let(:model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
    allow(RubyLLM.config).to receive(:default_model).and_return(model.id)
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
    allow(ChatResponseJob).to receive(:perform_later)
  end

  def submitted_question
    Nokogiri::HTML5(response.body).at_css("textarea[name='chat[prompt]']").text
  end

  it "offers a labelled question field and starts chat without a model picker" do
    get root_path

    html = Nokogiri::HTML5(response.body)
    form = html.at_css("form[action='#{start_chat_path}']")
    expect(form.at_css("label").text).to eq("What are you looking for?")
    expect(form.at_css("textarea")["placeholder"]).to eq("Where can I get a free meal downtown?")
    expect(form.at_css("button[type='submit']").text.squish).to eq("Start chat")
    expect(html.css("select")).to be_empty
    expect(response.body).not_to include("No account needed", "Please leave out names and personal details")
  end

  it "rejects a blank question without starting a guest chat" do
    expect { post start_chat_path, params: {chat: {prompt: " \n "}} }.not_to change(Chat, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Enter a question to start your chat.")
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "rejects malformed input without raising an exception" do
    post start_chat_path, params: {chat: "invalid"}

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Enter a question to start your chat.")
  end

  it "preserves an overlong question for editing without creating a chat" do
    long_question = "a" * 2001
    expect { post start_chat_path, params: {chat: {prompt: long_question}} }.not_to change(Chat, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Keep your question to 2,000 characters or fewer.")
    expect(submitted_question).to eq(long_question)
  end

  it "keeps a guest's failed question on the error page and clears it on refresh" do
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)
    post start_chat_path, params: {chat: {prompt: question}}, headers: {"X-Neighbourly-Guest-Token" => SecureRandom.hex(32)}
    expect(response).to have_http_status(:service_unavailable)
    expect(submitted_question).to eq(question)
    expect(request.session.to_hash.values).not_to include(question)
    expect(request.session[:landing_question_token]).to be_nil

    get root_path
    expect(submitted_question).to eq("")
  end

  it "expires signed-in visitors' unsent questions after thirty minutes" do
    sign_in user
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)
    post start_chat_path, params: {chat: {prompt: question}}
    travel 31.minutes do
      get root_path
      expect(submitted_question).to eq("")
    end
  end

  it "starts the signed-in visitor's chat with the default model and clears the draft" do
    sign_in user
    expect {
      post start_chat_path, params: {chat: {prompt: question, model: "untrusted-model"}}
    }.to change(Chat, :count).by(1).and change(ChatResponse, :count).by(1)

    chat = Chat.last
    expect(response).to redirect_to(chat_path(chat))
    expect(chat.user).to eq(user)
    expect(chat.model_id).to eq(model.id)
    expect(chat.messages.find_by!(role: "user").content).to eq(question)
    expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, question,
      hash_including(model: model.id, provider: "anthropic", response_id: Integer, attempt_token: String)).once
    expect(request.session[:landing_question_token]).to be_nil
    get root_path
    expect(submitted_question).to eq("")
  end

  it "retains the question and uses plain language when the default model is unavailable" do
    sign_in user
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)
    expect { post start_chat_path, params: {chat: {prompt: question}} }.not_to change(Chat, :count)

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("Chat is temporarily unavailable. Please try again later.")
    expect(submitted_question).to eq(question)
    get root_path
    expect(submitted_question).to eq(question)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "retains the question if saving the chat fails and rolls back its records" do
    sign_in user
    allow(ChatResponse).to receive(:enqueue!).and_raise(ActiveRecord::RecordInvalid.new(Chat.new))
    expect { post start_chat_path, params: {chat: {prompt: question}} }.not_to change(Chat, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(Nokogiri::HTML5(response.body).text).to include("We couldn't start your chat. Please try again.")
    expect(submitted_question).to eq(question)
    get root_path
    expect(submitted_question).to eq(question)
  end

  it "keeps the existing new-chat rate limit and preserves the blocked question" do
    sign_in user
    5.times { |number| post start_chat_path, params: {chat: {prompt: "Question #{number}"}} }
    expect { post start_chat_path, params: {chat: {prompt: question}} }.not_to change(Chat, :count)

    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response.body).to include("starting new chats too quickly")
    expect(submitted_question).to eq(question)
    expect(ChatResponseJob).to have_received(:perform_later).exactly(5).times
  end

  it "starts the signed-in chat even if temporary draft storage is unavailable" do
    sign_in user
    allow(Rails.cache).to receive(:write).and_return(nil)

    expect {
      post start_chat_path, params: {chat: {prompt: question}}
    }.to change(user.chats, :count).by(1).and change(ChatResponse, :count).by(1)

    chat = user.chats.last
    expect(response).to redirect_to(chat_path(chat))
    expect(chat.latest_response.user_message.content).to eq(question)
    expect(ChatResponseJob).to have_received(:perform_later).once
    expect(request.session[:landing_question_token]).to be_nil
  end
end
