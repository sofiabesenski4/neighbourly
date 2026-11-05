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

  it "offers a labelled question field and an honest sign-in action without a model picker" do
    get root_path

    html = Nokogiri::HTML5(response.body)
    form = html.at_css("form[action='#{start_chat_path}']")
    expect(form.at_css("label").text).to eq("What are you looking for?")
    expect(form.at_css("textarea")["placeholder"]).to eq("Where can I get a free meal downtown?")
    expect(form.at_css("button[type='submit']").text.squish).to eq("Sign in to start chat")
    expect(html.css("select")).to be_empty
    expect(response.body).not_to include("No account needed", "Please leave out names and personal details")
  end

  it "rejects a blank question before asking a guest to sign in" do
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

  it "keeps a guest question through a failed sign-in and returns it for review after sign-in" do
    user
    expect { post start_chat_path, params: {chat: {prompt: question}} }.not_to change(Chat, :count)
    expect(response).to redirect_to(new_user_session_path)
    expect(request.session[:landing_question_token]).to be_present
    expect(request.session.to_hash.values).not_to include(question)
    expect(response.location).not_to include("meal", "prompt")
    follow_redirect!

    post user_session_path, params: {user: {email: user.email, password: "wrong-password"}}
    expect(response).to have_http_status(:unprocessable_content)
    post user_session_path, params: {user: {email: user.email, password: "password123"}}
    expect(response).to redirect_to(root_path)
    follow_redirect!

    expect(submitted_question).to eq(question)
    expect(response.body).to include("Start chat")
    expect(ChatResponseJob).not_to have_received(:perform_later)
    expect(Chat.count).to eq(0)
  end

  it "also preserves the question when the visitor creates an account" do
    post start_chat_path, params: {chat: {prompt: question}}
    get new_user_registration_path
    post user_registration_path, params: {user: {email: "new-neighbour@example.com", password: "password123", password_confirmation: "password123"}}

    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(submitted_question).to eq(question)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "keeps the question private to the visitor's session" do
    post start_chat_path, params: {chat: {prompt: question}}
    other_visitor = open_session
    other_visitor.get root_path

    expect(Nokogiri::HTML5(other_visitor.response.body).at_css("textarea[name='chat[prompt]']").text).to eq("")
    get root_path
    expect(submitted_question).to eq(question)
  end

  it "expires unsent questions after thirty minutes" do
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

  it "keeps the entered text on screen if temporary draft storage is unavailable" do
    allow(Rails.cache).to receive(:write).and_return(false)
    post start_chat_path, params: {chat: {prompt: question}}

    expect(response).to have_http_status(:service_unavailable)
    expect(Nokogiri::HTML5(response.body).text).to include("We couldn't keep your question while you sign in. Please try again.")
    expect(submitted_question).to eq(question)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end
end
