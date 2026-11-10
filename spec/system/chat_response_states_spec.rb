require "rails_helper"

RSpec.describe "Chat response states", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
    allow(ChatResponseJob).to receive(:perform_later)
  end

  let(:user) { User.create!(email: "response-states@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Community resources") }

  it "shows the question immediately, tracks progress, and preserves the next draft" do
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    fill_in "Message", with: "Find meals in Victoria"
    click_button "Send message"

    expect(page).to have_field("Message", with: "")
    record = chat.chat_responses.last
    expect(page).to have_css("#message_#{record.user_message_id}_content", text: "Find meals in Victoria")
    expect(page).to have_text("Getting ready")
    fill_in "Message", with: "My next question"
    expect(page).to have_button("Send message", disabled: true)

    record.update!(status: "searching")
    expect(page).to have_text("Finding local resources")
    record.update!(status: "writing")
    expect(page).to have_text("Writing a response")
    record.update!(status: "completed")

    expect(page).to have_button("Send message", disabled: false)
    expect(page).to have_field("Message", with: "My next question")
    expect(page).not_to have_text("Writing a response")
  end

  it "keeps a failed question and its failure visible after reload" do
    visit chat_path(chat)
    fill_in "Message", with: "Find a shelter"
    click_button "Send message"
    expect(page).to have_field("Message", with: "")
    chat.chat_responses.last.update!(status: "failed", error_message: "The reply could not be completed. Your question is saved.")

    expect(page).to have_text("Your question is saved.")
    page.refresh
    expect(page).to have_css("#messages", text: "Find a shelter")
    expect(page).to have_text("Your question is saved.")
  end
end
