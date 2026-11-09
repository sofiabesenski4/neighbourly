require "rails_helper"

RSpec.describe "Chats", type: :system do
  before do
    driven_by(:rack_test)
  end

  let(:user) { User.create!(email: "chatuser@example.com", password: "password123") }

  # A real registry holding only these two models, so we never hit the
  # real API just to render a <select>. Saving a chat copies its model into
  # ruby_llm_models, so a bare double is not enough.
  let(:default_model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:alternate_model) { RubyLLM::Model.new(id: "claude-sonnet-4-5", name: "Claude Sonnet", provider: "anthropic") }
  let(:model_catalogue) { RubyLLM::Models.new([default_model, alternate_model]) }

  before do
    allow(RubyLLM).to receive(:models).and_return(model_catalogue)

    allow(ChatResponseJob).to receive(:perform_later)
  end

  it "allows logged in users to start chats" do
    login_as(user, scope: :user)

    visit new_chat_path

    fill_in "Prompt", with: "Hello, how are you?"
    click_button "Start new chat"

    expect(page).to have_content("Chat was successfully created.", count: 1)
    expect(Chat.last.user).to eq(user)
  end

  it "shows the guest composer and requires JavaScript to submit it" do
    visit new_chat_path

    expect(page).to have_content("Guest chat.")
    expect(page).to have_link("Sign in", href: new_user_session_path)
    fill_in "Prompt", with: "Where can I find a meal?"

    expect { click_button "Start new chat" }.not_to change(Chat, :count)
    expect(page).to have_content("Enable JavaScript and reopen Chat to start a guest conversation.")
    expect(page).to have_field("Prompt", with: "Where can I find a meal?")
  end

  context "when logged in" do
    before { login_as(user, scope: :user) }

    it "uses LLMs to answer questions" do
      visit new_chat_path

      fill_in "Prompt", with: "What is Ruby on Rails?"
      click_button "Start new chat"

      chat = Chat.last
      expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, "What is Ruby on Rails?", hash_including(model: chat.model_id, provider: chat.provider.to_s, response_id: Integer, attempt_token: String))
    end

    it "opens a saved chat from the workspace after visiting the old list URL" do
      chat = user.chats.create!(title: "Saved conversation")
      visit chats_path

      expect(page).to have_current_path(new_chat_path)
      expect(page).not_to have_link("All chats")
      within("#chat_sidebar") { click_link "Saved conversation" }
      expect(page).to have_current_path(chat_path(chat))
    end

    it "hides the admin-only Models link" do
      visit new_chat_path

      expect(page).not_to have_link("Models")
    end

    it "shows a chat and its messages" do
      chat = user.chats.create!
      chat.messages.create!(role: "user", content: "Hi there")
      chat.messages.create!(role: "assistant", content: "Hello! How can I help?")

      visit chat_path(chat)

      expect(page).to have_content("Hi there")
      expect(page).to have_content("Hello! How can I help?")
    end

    it "allows selecting an AI model for the chat" do
      visit new_chat_path

      expect(page).to have_select("chat_model", options: ["Anthropic - Claude Haiku", "Anthropic - Claude Sonnet"])

      select "Anthropic - Claude Sonnet", from: "chat_model"
      fill_in "Prompt", with: "Tell me about Rails"
      click_button "Start new chat"

      expect(Chat.last.model_id).to eq("claude-sonnet-4-5")
    end

    it "enqueues the job for follow-up messages" do
      chat = user.chats.create!

      visit chat_path(chat)

      fill_in "Message", with: "Follow-up question"
      click_button "Send message"

      expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, "Follow-up question", hash_including(model: chat.model_id, provider: chat.provider.to_s, response_id: Integer, attempt_token: String))
    end
  end

  context "when logged in as an admin" do
    let(:admin) { User.create!(email: "chatadmin@example.com", password: "password123", admin: true) }

    before { login_as(admin, scope: :user) }

    it "links to the Models page" do
      visit new_chat_path
      within("#chat_sidebar") { click_link "Models" }

      expect(page).to have_current_path(models_path)
      within("main") { click_link "Chats" }
      expect(page).to have_current_path(new_chat_path)
    end
  end

  context "when logged in as an admin" do
    let(:admin) { User.create!(email: "chatadmin@example.com", password: "password123", admin: true) }

    before { login_as(admin, scope: :user) }

    it "links to the Models page" do
      visit chats_path
      click_link "Models"

      expect(page).to have_current_path(models_path)
    end
  end
end
