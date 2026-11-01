require "rails_helper"

RSpec.describe "Automatic chat titles", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
  end

  let(:user) { User.create!(email: "livetitles@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  it "updates the fallback and generated title live in the header, sidebar, drawer, and browser tab" do
    visit chat_path(chat)
    expect(page).to have_css("h1", text: "New conversation")
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)

    chat.messages.create!(role: "user", content: "I need free food in Victoria")
    expect(page).to have_css("h1", text: "I need free food in Victoria")

    chat.messages.create!(role: "assistant", content: "Here are some options.")
    llm = instance_double(RubyLLM::Chat)
    allow(RubyLLM).to receive(:chat).and_return(llm)
    allow(llm).to receive(:with_instructions).and_return(llm)
    allow(llm).to receive(:with_max_output_tokens).and_return(llm)
    allow(llm).to receive(:ask).and_return(double("response", content: "Food support in Victoria"))

    ChatTitleJob.perform_now(chat.id)

    expect(page).to have_css("h1", text: "Food support in Victoria")
    expect(page).to have_css("#chat_sidebar a[aria-current='page']", text: "Food support in Victoria")
    expect(page).to have_css("#chat_drawer a[aria-current='page']", text: "Food support in Victoria", visible: :all)
    expect(page).to have_title("Food support in Victoria")

    page.refresh
    expect(page).to have_css("h1", text: "Food support in Victoria")
  end

  it "renders generated titles as plain text" do
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)

    chat.update!(title: "<img src=x onerror=alert(1)>")

    expect(page).to have_css("h1", text: "<img src=x onerror=alert(1)>")
    expect(page).not_to have_css("h1 img, #chat_sidebar img", visible: :all)
  end
end
