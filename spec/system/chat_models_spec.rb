require "rails_helper"

RSpec.describe "Composer model picker", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([default_model, alternate_model]))
    allow(ChatResponseJob).to receive(:perform_later)
  end

  let(:user) { User.create!(email: "composer-models@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:default_model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:alternate_model) { RubyLLM::Model.new(id: "claude-sonnet-4-5", name: "Claude Sonnet", provider: "anthropic") }

  it "places the model picker inside the new-chat composer" do
    visit new_chat_path

    within("#new_chat") do
      select "Anthropic - Claude Sonnet", from: "Model"
      fill_in "Prompt", with: "Find local meals"
      click_button "Start new chat"
    end

    expect(page).to have_content("Chat was successfully created.")
    expect(Chat.last.model_id).to eq(alternate_model.id)
  end

  it "switches the model for the next message while preserving earlier replies" do
    chat.messages.create!(role: "user", content: "Where can I eat?")
    chat.messages.create!(role: "assistant", content: "Earlier reply from the original model.")
    visit chat_path(chat)

    within("#new_message") do
      select "Anthropic - Claude Sonnet", from: "Model"
      fill_in "Message", with: "What is open today?"
      click_button "Send message"
    end

    expect(page).to have_field("Message", with: "")
    expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, "What is open today?", model: alternate_model.id, provider: "anthropic", response_id: Integer)
    expect(page).to have_select("message_model", selected: "Anthropic - Claude Sonnet")
    expect(page).to have_content("Earlier reply from the original model.")
  end
end
