require "rails_helper"

RSpec.describe "Retrying a failed reply", type: :system do
  let(:user) { User.create!(email: "retry-browser@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  before do
    driven_by(:selenium_chrome_headless)
    login_as(user, scope: :user)
    allow(ChatResponseJob).to receive(:perform_later)
  end

  it "retries after a refresh, removes the partial answer, and keeps the next draft" do
    record = ChatResponse.enqueue!(chat: chat, content: "Find free meals", model: chat.model_id, provider: chat.provider)
    partial = chat.messages.create!(role: "assistant", content: "This answer was interrupted")
    record.update!(assistant_message: partial)
    record.fail!

    visit chat_path(chat)
    page.refresh
    expect(page).to have_button("Retry reply")
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    fill_in "Message", with: "My next question"
    click_button "Retry reply"

    expect(page).to have_text("Getting ready")
    expect(page).not_to have_text("This answer was interrupted")
    expect(page).not_to have_button("Retry reply")
    expect(page).to have_field("Message", with: "My next question")
    expect(page).to have_button("Send message", disabled: true)
    expect(chat.messages.where(role: "user").count).to eq(1)

    record.reload.fail!
    expect(page).to have_button("Retry reply")
    expect(page).to have_field("Message", with: "My next question")
    expect(page).to have_button("Send message", disabled: false)
  end
end
