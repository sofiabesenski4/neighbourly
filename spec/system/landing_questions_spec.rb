require "rails_helper"

RSpec.describe "Landing question composer", type: :system do
  let(:user) { User.create!(email: "question-composer@example.com", password: "password123") }
  let(:model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }

  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 1000)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
    allow(RubyLLM.config).to receive(:default_model).and_return(model.id)
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
    allow(ChatResponseJob).to receive(:perform_later)
  end

  it "fills and focuses each suggestion without submitting or opening another page" do
    visit root_path
    expect(page).to have_button("Start chat", disabled: true)

    {
      "Find food" => "Where can I get a free meal downtown?",
      "Find shelter" => "Where can I find shelter tonight?",
      "Find a shower" => "Where can I have a shower?"
    }.each do |label, question|
      click_button label
      expect(page).to have_field("What are you looking for?", with: question)
      expect(find_field("What are you looking for?")).to match_css(":focus")
      expect(page).to have_current_path(root_path)
    end
    expect(page).to have_button("Start chat", disabled: false)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "starts a guest conversation with a multiline question" do
    visit root_path
    fill_in "What are you looking for?", with: "Find a meal"
    find_field("What are you looking for?").send_keys(:enter, "near downtown")
    question = "Find a meal\nnear downtown"
    expect(page).to have_field("What are you looking for?", with: question)
    expect(ChatResponseJob).not_to have_received(:perform_later)
    click_button "Start chat", exact: true

    expect(page).to have_content("Chat was successfully created.")
    expect(page).to have_current_path(guest_chat_path(Chat.last))
    expect(page).to have_content("Find a meal")
    expect(page).to have_content("Guest chat")
    expect(Chat.last.messages.find_by!(role: "user").content).to eq(question)
    expect(ChatResponseJob).to have_received(:perform_later).once
  end

  it "continues in the open tab and starts fresh in another tab or after refresh" do
    visit root_path
    fill_in "What are you looking for?", with: "A question from the last visitor"
    click_button "Start chat", exact: true
    expect(page).to have_content("A question from the last visitor")
    chat = Chat.last
    guest_path = guest_chat_path(chat)

    click_button "Stop response"
    expect(page).to have_content("Response stopped.")
    fill_in "Message", with: "A follow-up from this tab"
    click_button "Send message"
    expect(page).to have_content("A follow-up from this tab")

    # Simulate a reply missed by the live connection and recover it over HTTP.
    page.execute_script("document.querySelector('turbo-cable-stream-source')?.remove()")
    reply = chat.latest_response
    answer = chat.messages.create!(role: "assistant", content: "Try a community kitchen.")
    reply.update!(status: :completed, assistant_message: answer)
    page.execute_script("window.dispatchEvent(new Event('online'))")
    expect(page).to have_content("Try a community kitchen.")

    within_window(open_new_window) do
      visit guest_path
      expect(page).to have_current_path(new_chat_path)
      expect(page).not_to have_content("A question from the last visitor")
    end

    refresh
    expect(page).to have_current_path(new_chat_path)
    expect(page).not_to have_content("A question from the last visitor")
  end

  it "saves both guest chats after correcting a failed sign-in" do
    visit root_path
    fill_in "What are you looking for?", with: "Where are the free meals?"
    click_button "Start chat", exact: true
    expect(page).to have_content("Where are the free meals?")
    first_chat = Chat.last

    click_link "New chat", exact: true
    fill_in "Prompt", with: "Where can I find shelter?"
    click_button "Start new chat"
    expect(page).to have_content("Where can I find shelter?")
    guest_chat = Chat.last

    click_link "Sign in to save your chats"
    expect(page).to have_checked_field("Save guest chats")
    fill_in "Email address", with: user.email
    fill_in "Password", with: "wrong-password"
    click_button "Sign in", exact: true
    expect(page).to have_content("Invalid email or password.")
    expect(page).to have_checked_field("Save guest chats")
    expect(guest_chat.reload).to be_guest

    fill_in "Email address", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in", exact: true
    expect(page).to have_current_path(chat_path(guest_chat))
    expect(page).to have_content("Where can I find shelter?")
    expect(guest_chat.reload.user).to eq(user)
    expect(first_chat.reload.user).to eq(user)
    expect(page).to have_link(href: chat_path(guest_chat), exact: true)
    page.refresh
    find_link("Where are the free meals?", href: chat_path(first_chat)).click
    expect(page).to have_content("Where are the free meals?")
  end

  it "lets the visitor sign in without saving the guest chat" do
    visit root_path
    fill_in "What are you looking for?", with: "Find shelter tonight"
    click_button "Start chat", exact: true
    expect(page).to have_content("Find shelter tonight")
    guest_chat = Chat.last

    click_link "Sign in to save your chats"
    uncheck "Save guest chats"
    fill_in "Email address", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in", exact: true

    expect(page).to have_button("Sign out")
    expect(guest_chat.reload).to be_guest
    expect(user.chats).to be_empty
  end

  it "keeps a guest conversation while using Printout in the same tab" do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
    source = Source.create!(name: "Local guide", source_type: "api")
    source.documents.create!(title: "Community meal", content: "Free meals downtown")

    visit root_path
    fill_in "What are you looking for?", with: "Find a meal near downtown"
    click_button "Start chat", exact: true
    expect(page).to have_content("Find a meal near downtown")
    conversation = guest_chat_path(Chat.last)
    page.execute_script(<<~JS)
      window.guestPrintoutViolations = [];
      document.addEventListener('securitypolicyviolation', (event) => {
        window.guestPrintoutViolations.push(event.effectiveDirective);
      });
    JS

    find("nav[aria-label='Main navigation']").click_link "Printout", exact: true
    expect(page).to have_current_path(new_flyer_path)
    expect(page.evaluate_script("window.guestPrintoutViolations")).to eq([])
    click_button "Generate printout"
    expect(page).to have_link("Open PDF", href: /\Ablob:/)
    expect(page).to have_css('iframe[title="Printable resource guide"][src^="blob:"]', visible: :all)
    expect(page.evaluate_script("window.guestPrintoutViolations")).not_to include("frame-src", "object-src")

    page.go_back
    expect(page).to have_current_path(conversation)
    expect(page).to have_content("Find a meal near downtown")

    find("nav[aria-label='Main navigation']").click_link "Printout", exact: true
    expect(page).to have_current_path(new_flyer_path)
    find("nav[aria-label='Main navigation']").click_link "Chat", exact: true
    expect(page).to have_current_path(conversation)
    expect(page).to have_content("Find a meal near downtown")
  end

  it "keeps the signed-in visitor's question editable after a failed start" do
    login_as(user, scope: :user)
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return(nil)
    visit root_path
    fill_in "What are you looking for?", with: "Where can I find a shower?"
    click_button "Start chat", exact: true

    expect(page).to have_content("Chat is temporarily unavailable. Please try again later.")
    expect(page).to have_field("What are you looking for?", with: "Where can I find a shower?")
    expect(find_field("What are you looking for?")["aria-invalid"]).to eq("true")
    expect(page).to have_button("Start chat", disabled: false)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "sends a question from the compact composer on a narrow phone screen" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit root_path
    within("section[aria-label='Start a chat']") do
      expect(page).to have_no_css("[aria-label='Suggested questions']")
      input = find_field("What are you looking for?")
      send_button = find("button[type='submit']:disabled")
      expect(send_button.text).to be_empty
      expect(send_button.evaluate_script("this.getBoundingClientRect().width")).to be >= 44
      expect(send_button.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      expect(send_button.evaluate_script("this.getBoundingClientRect().left"))
        .to be >= input.evaluate_script("this.getBoundingClientRect().right")
      expect(send_button.evaluate_script("this.getBoundingClientRect().top"))
        .to be < input.evaluate_script("this.getBoundingClientRect().bottom")

      input.set("Find a meal near downtown")
      expect(page).to have_css("button[type='submit']:enabled")
    end
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    find("section[aria-label='Start a chat'] button[type='submit']").click
    expect(page).to have_content("Guest chat")
    expect(page).to have_content("Find a meal near downtown")
    expect(ChatResponseJob).to have_received(:perform_later).once
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "restores the text button and suggestions at 640 px" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 640, height: 800, deviceScaleFactor: 1, mobile: false)
    visit root_path

    expect(page).to have_button("Start chat", disabled: true)
    expect(page).to have_button("Find food")
    expect(page).to have_button("Find shelter")
    expect(page).to have_button("Find a shower")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
