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

    expect(page).to have_content("Chat was successfully created.")
    expect(Chat.last.user).to eq(user)
  end

  it "prevents guest users from creating chats" do
    visit new_chat_path

    expect(page).to have_content("Sign in to your account")
    expect(page).not_to have_content("New chat")
  end

  context "when logged in" do
    before { login_as(user, scope: :user) }

    it "uses LLMs to answer questions" do
      visit new_chat_path

      fill_in "Prompt", with: "What is Ruby on Rails?"
      click_button "Start new chat"

      chat = Chat.last
      expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, "What is Ruby on Rails?")
    end

    it "lists existing chats on the index page" do
      chat = user.chats.create!
      # The index renders message count and creation date
      visit chats_path

      expect(page).to have_content("Chats")
      expect(page).to have_content(chat.created_at.strftime("%B %d, %Y"))
    end

    it "shows a chat and its messages" do
      chat = user.chats.create!
      chat.messages.create!(role: "user", content: "Hi there")
      chat.messages.create!(role: "assistant", content: "Hello! How can I help?")

      visit chat_path(chat)

      expect(page).to have_content("Hi there")
      expect(page).to have_content("Hello! How can I help?")
    end

    it "destroys a chat from the index page" do
      user.chats.create!

      visit chats_path
      click_button "Destroy"

      expect(page).to have_content("Chat was successfully destroyed.")
      expect(Chat.count).to eq(0)
    end

    it "allows selecting an AI model for the chat" do
      visit new_chat_path

      expect(page).to have_select("chat_model", options: ["Default: Anthropic - Claude Haiku", "Anthropic - Claude Haiku", "Anthropic - Claude Sonnet"])

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

      expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, "Follow-up question")
    end

    it "creates a chat with RAG enabled when the toggle is checked" do
      visit new_chat_path

      fill_in "Prompt", with: "Where can I find shelter?"
      check "Search local resources"
      click_button "Start new chat"

      expect(Chat.last.use_rag).to be true
    end

    it "creates a chat without RAG by default" do
      visit new_chat_path

      fill_in "Prompt", with: "Hello"
      click_button "Start new chat"

      expect(Chat.last.use_rag).to be false
    end
  end
end
