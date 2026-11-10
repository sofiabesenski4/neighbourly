require "rails_helper"

RSpec.describe "Mobile chat", type: :system do
  let(:user) { User.create!(email: "mobile-chat@example.com", password: "password123", admin: true) }
  let(:default_model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:alternate_model) { RubyLLM::Model.new(id: "claude-sonnet-4-5", name: "Claude Sonnet with a long display name", provider: "anthropic") }
  let!(:chat) { user.chats.create!(title: "Find nearby meals and community support in Greater Victoria") }

  before do
    driven_by(:selenium_chrome_headless)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    allow(ChatResponseJob).to receive(:perform_later)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([default_model, alternate_model]))
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
    login_as(user, scope: :user)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.current_window.resize_to(1280, 900)
  end

  [[320, 740], [844, 390], [768, 1024]].each do |width, height|
    it "keeps model selection and sending usable at #{width} by #{height}" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: true)
      visit new_chat_path

      select alternate_model.label, from: "Model"
      fill_in "Prompt", with: "Where can I find a free meal?"
      [find_field("Prompt"), find_field("Model")].each do |field|
        expect(field.evaluate_script("parseFloat(getComputedStyle(this).fontSize)")).to be >= 16
        expect(field.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
      end
      [find_field("Model"), find_button("Start new chat")].each do |control|
        expect(control.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
        expect(control.evaluate_script("this.getBoundingClientRect().bottom <= window.innerHeight")).to be(true)
      end
      expect(find("[aria-label='Conversation']").evaluate_script("this.clientHeight")).to be > 0
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)

      click_button "Start new chat"

      expect(page).to have_field("Message", with: "")
      expect(Chat.last.model_id).to eq(alternate_model.id)
      expect(ChatResponseJob).to have_received(:perform_later).with(Chat.last.id, "Where can I find a free meal?", hash_including(model: alternate_model.id)).once
      expect(find_button("Send message", disabled: true).evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      expect(find_field("Message").evaluate_script("parseFloat(getComputedStyle(this).fontSize)")).to be >= 16
    end
  end

  it "keeps conversation navigation and actions reachable on a narrow phone" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 740, deviceScaleFactor: 1, mobile: true)
    visit new_chat_path
    toggle = find("button[aria-label='Open conversations']")
    expect(toggle.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
    toggle.click

    within("#chat_drawer[open]") do
      expect(find_button("Close").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      expect(find_link(chat.title).evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      actions = find("button[aria-haspopup='menu']")
      expect(actions.evaluate_script("this.getBoundingClientRect().width")).to be >= 44
      actions.click
    end
    expect(find_button("Delete conversation").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
    within("#chat_drawer[open]") { click_button "Close" }
    find("button[aria-label='Open conversations']").click
    within("#chat_drawer[open]") { click_link chat.title }
    expect(page).to have_current_path(chat_path(chat))
    expect(page).not_to have_css("#chat_drawer[open]")
  end
end
