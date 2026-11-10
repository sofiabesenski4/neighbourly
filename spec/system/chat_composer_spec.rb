require "rails_helper"

RSpec.describe "Chat composer ergonomics", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
    allow(ChatResponseJob).to receive(:perform_later)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([default_model, alternate_model]))
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1280, 900)
  end

  let(:user) { User.create!(email: "ergonomics@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Local resources") }
  let(:default_model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:alternate_model) { RubyLLM::Model.new(id: "claude-sonnet-4-5", name: "Claude Sonnet", provider: "anthropic") }

  def paste_draft(label, text)
    field = find_field(label)
    field.click
    field.execute_script(<<~JS, text)
      this.value = arguments[0];
      this.setSelectionRange(this.value.length, this.value.length);
      this.dispatchEvent(new InputEvent("input", {bubbles: true, inputType: "insertFromPaste", data: arguments[0]}));
    JS
  end

  it "starts a new conversation with Enter using the selected model" do
    visit new_chat_path
    select "Anthropic - Claude Sonnet", from: "Model"
    fill_in "Prompt", with: "Find free meals in Victoria"
    find_field("Prompt").send_keys(:enter)

    expect(page).to have_content("Chat was successfully created.")
    expect(Chat.last.model_id).to eq(alternate_model.id)
    expect(ChatResponseJob).to have_received(:perform_later).with(Chat.last.id, "Find free meals in Victoria", hash_including(model: alternate_model.id, provider: "anthropic", response_id: Integer, attempt_token: String)).once
  end

  it "inserts a newline with Shift+Enter and continues working after the composer is replaced" do
    visit chat_path(chat)
    fill_in "Message", with: "Find meals"
    find_field("Message").send_keys([:shift, :enter], "in Victoria")

    expect(page).to have_field("Message", with: "Find meals\nin Victoria")
    expect(ChatResponseJob).not_to have_received(:perform_later)

    find_field("Message").send_keys(:enter)
    expect(page).to have_field("Message", with: "")
    expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, "Find meals\nin Victoria", model: chat.model_id, provider: chat.provider.to_s, response_id: Integer, attempt_token: String).once

    chat.chat_responses.last.complete!
    expect(page).not_to have_content("Getting ready…")
    fill_in "Message", with: "What is open today?"
    find_field("Message").send_keys(:enter)
    expect(page).to have_field("Message", with: "")
    expect(ChatResponseJob).to have_received(:perform_later).with(chat.id, "What is open today?", model: chat.model_id, provider: chat.provider.to_s, response_id: Integer, attempt_token: String).once
  end

  it "does not send blank drafts" do
    visit new_chat_path
    expect(page).to have_button("Start new chat", disabled: true)
    fill_in "Prompt", with: " \n "
    find_field("Prompt").send_keys(:enter)

    expect(page).to have_button("Start new chat", disabled: true)
    expect(page).to have_current_path(new_chat_path)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "does not send while confirming IME input or holding Enter down" do
    visit new_chat_path
    fill_in "Prompt", with: "Find meals"
    field = find_field("Prompt")
    page.execute_script('window.composerSubmitCount = 0; document.querySelector("#new_chat").addEventListener("submit", () => window.composerSubmitCount++)')

    [{isComposing: true}, {keyCode: 229}].each do |options|
      prevented = field.evaluate_script(<<~JS)
        (() => {
          const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...#{options.to_json} });
          this.dispatchEvent(event);
          return event.defaultPrevented;
        })()
      JS
      expect(prevented).to be(false)
    end

    field.execute_script('this.dispatchEvent(new KeyboardEvent("keydown", {key: "Enter", repeat: true, bubbles: true, cancelable: true}))')
    expect(page).to have_current_path(new_chat_path)
    expect(page).to have_field("Prompt", with: "Find meals")
    expect(page.evaluate_script("window.composerSubmitCount")).to eq(0)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "grows for pasted drafts, caps its height, and shrinks when cleared" do
    visit chat_path(chat)
    field = find_field("Message")
    initial_height = field.evaluate_script("this.getBoundingClientRect().height")
    draft = "A line in a long draft\n" * 30
    paste_draft("Message", draft)

    expect(page).to have_css("#message_content") do |input|
      input.evaluate_script("this.getBoundingClientRect().height") > initial_height
    end
    expect(field.evaluate_script("this.getBoundingClientRect().height <= Math.min(192, window.innerHeight * 0.25) + 1")).to be(true)
    expect(field.evaluate_script("this.scrollHeight > this.clientHeight")).to be(true)
    expect(page).to have_field("Message", with: draft)
    expect(ChatResponseJob).not_to have_received(:perform_later)

    fill_in "Message", with: ""
    expect(page).to have_css("#message_content") do |input|
      (input.evaluate_script("this.getBoundingClientRect().height") - initial_height).abs <= 1
    end
    expect(page).to have_button("Send message", disabled: true)
  end

  it "reflows after the sidebar collapses and keeps the send button visible on mobile" do
    page.current_window.resize_to(900, 900)
    visit chat_path(chat)
    fill_in "Message", with: "Where can I find free meals nearby? " * 8
    field = find_field("Message")
    original_height = field.evaluate_script("this.clientHeight")
    find("button[aria-label='Toggle conversation sidebar']").click

    expect(page).to have_css("#message_content") do |input|
      input.evaluate_script("this.clientHeight") < original_height
    end

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    paste_draft("Message", "A mobile draft\n" * 30)
    expect(find_button("Send message").evaluate_script("this.getBoundingClientRect().bottom <= window.innerHeight")).to be(true)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end

  it "fills an editable starter question without submitting or changing the model" do
    visit new_chat_path
    select "Anthropic - Claude Sonnet", from: "Model"
    click_button "Find free meals"

    expect(page).to have_field("Prompt", with: "Where can I find free meals?")
    expect(page).to have_select("chat_model", selected: "Anthropic - Claude Sonnet")
    expect(page.evaluate_script("document.activeElement.id")).to eq("chat_prompt")
    expect(page).to have_button("Start new chat", disabled: false)
    expect(ChatResponseJob).not_to have_received(:perform_later)
  end
end
