require "rails_helper"

RSpec.describe "Chat workspace", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
    allow(ChatResponseJob).to receive(:perform_later)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1280, 900)
  end

  let(:user) { User.create!(email: "workspace@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  it "matches the landing header and opens Chat directly in the workspace" do
    visit root_path
    landing_brand = find("nav[aria-label='Main navigation']").find_link("neighbourly")
    brand_position = landing_brand.evaluate_script("this.getBoundingClientRect().left")
    visit chat_path(chat)

    brand = find("nav[aria-label='Main navigation']").find_link("neighbourly")
    expect(brand.evaluate_script("this.getBoundingClientRect().left"))
      .to eq(brand_position)
    expect(page).to have_css("nav a[aria-current='page']", text: "Chat")

    within("nav[aria-label='Main navigation']") { click_link "Chat", exact: true }
    expect(page).to have_current_path(new_chat_path)
    expect(page).to have_css("h2", text: "What would you like help finding?")
  end

  it "places user messages on the right and assistant replies on the left" do
    question = chat.messages.create!(role: "user", content: "Where can I find a meal?")
    reply = chat.messages.create!(role: "assistant", content: "Try **Rainbow Kitchen**.")
    visit chat_path(chat)

    messages = find("#messages")
    bubble = find("#message_#{question.id} > div")
    assistant = find("#message_#{reply.id}")
    expect(bubble.evaluate_script("this.getBoundingClientRect().right"))
      .to be_within(1).of(messages.evaluate_script("this.getBoundingClientRect().right"))
    expect(bubble.evaluate_script("this.getBoundingClientRect().left"))
      .to be > assistant.evaluate_script("this.getBoundingClientRect().left")
    expect(assistant.evaluate_script("this.getBoundingClientRect().left"))
      .to eq(messages.evaluate_script("this.getBoundingClientRect().left"))
    expect(assistant).to have_css("strong", text: "Rainbow Kitchen")
  end

  it "collapses the desktop sidebar without leaving the conversation" do
    chat.messages.create!(role: "user", content: "Find food in Victoria")
    visit chat_path(chat)

    expect(page).to have_css("h1", text: "Find food in Victoria")
    expect(page).to have_css("#chat_sidebar a[aria-current='page']", text: "Find food in Victoria")
    find("button[aria-label='Toggle conversation sidebar']").click
    expect(page).not_to have_css("#chat_sidebar")
    expect(find("button[aria-label='Toggle conversation sidebar']")["aria-expanded"]).to eq("false")
    expect(page).to have_field("Message")

    find("button[aria-label='Toggle conversation sidebar']").click
    expect(page).to have_css("#chat_sidebar")
    expect(find("button[aria-label='Toggle conversation sidebar']")["aria-expanded"]).to eq("true")
  end

  it "opens a mobile drawer, closes it with Escape, and navigates to a recent conversation" do
    chat.messages.create!(role: "user", content: "Find nearby meals")
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    visit new_chat_path

    expect(page).not_to have_css("#chat_sidebar")
    expect(page).to have_css("h2", text: "What would you like help finding?")
    find("button[aria-label='Open conversations']").click
    expect(page).to have_css("#chat_drawer[open]")
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("Close")
    find("#chat_drawer").send_keys(:escape)
    expect(page).not_to have_css("#chat_drawer[open]")
    expect(page).to have_css("button[aria-label='Open conversations'][aria-expanded='false']")

    find("button[aria-label='Open conversations']").click
    within("#chat_drawer") { click_link "Find nearby meals" }
    expect(page).to have_current_path(chat_path(chat))
    expect(page).to have_css("h1", text: "Find nearby meals")
    expect(page).to have_button("Send message", disabled: true)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)

    page.go_back
    expect(page).to have_current_path(new_chat_path)
    expect(page).not_to have_css("#chat_drawer[open]")
    expect(page).to have_css("button[aria-label='Open conversations'][aria-expanded='false']")
  end

  it "keeps the composer visible while a long conversation scrolls independently" do
    12.times { chat.messages.create!(role: "user", content: "A long question\n" * 10) }
    visit chat_path(chat)

    composer = find("#new_message")
    position = composer.evaluate_script("this.getBoundingClientRect().top")
    conversation = find("[aria-label='Conversation']")
    conversation.evaluate_script("this.scrollTop = this.scrollHeight")

    expect(conversation.evaluate_script("this.scrollTop")).to be > 0
    expect(composer.evaluate_script("this.getBoundingClientRect().top")).to eq(position)
    expect(composer.evaluate_script("this.getBoundingClientRect().bottom <= window.innerHeight")).to be(true)
    expect(find("#messages").evaluate_script("this.getBoundingClientRect().width")).to be <= 768
  end

  it "submits the model selected in the composer for a new chat" do
    default_model = RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic")
    alternate_model = RubyLLM::Model.new(id: "claude-sonnet-4-5", name: "Claude Sonnet", provider: "anthropic")
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([default_model, alternate_model]))

    visit new_chat_path
    select "Anthropic - Claude Sonnet", from: "chat_model"
    fill_in "Prompt", with: "Find food support"
    click_button "Start new chat"

    expect(page).to have_content("Chat was successfully created.")
    expect(Chat.last.model_id).to eq("claude-sonnet-4-5")
    expect(ChatResponseJob).to have_received(:perform_later).with(Chat.last.id, "Find food support", hash_including(model: alternate_model.id, provider: "anthropic", response_id: Integer))
  end
end
