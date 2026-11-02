require "rails_helper"

RSpec.describe "Stopping a reply", type: :system do
  let(:user) { User.create!(email: "stop-browser@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  before do
    driven_by(:selenium_chrome_headless)
    login_as(user, scope: :user)
    allow(ChatResponseJob).to receive(:perform_later).and_return(true)
  end

  it "stops the running reply without discarding the next draft" do
    record = ChatResponse.enqueue!(chat: chat, content: "Find free meals", model: chat.model_id, provider: chat.provider)
    record.claim!
    record.start_writing!

    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    fill_in "Message", with: "My next question"
    click_button "Stop response"

    expect(page).to have_text("Stopping")
    expect(page).to have_button("Send message", disabled: true)
    expect(page).to have_field("Message", with: "My next question")

    record.reload.acknowledge_cancellation!
    expect(page).to have_text("Response stopped")
    expect(page).to have_button("Send message", disabled: false)
    expect(page).to have_field("Message", with: "My next question")
    expect(chat.messages.where(role: "user").count).to eq(1)
  end
end
