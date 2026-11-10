require "rails_helper"

RSpec.describe "Flash notifications", type: :system do
  let(:user) { User.create!(email: "notifications@example.com", password: "password123") }

  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
    allow(ChatResponseJob).to receive(:perform_later)
  end

  def start_conversation
    visit new_chat_path
    # Keep the toast focused while checking layout and navigation. turbo:load
    # runs after the destination page applies its normal composer autofocus.
    page.execute_script(<<~JS)
      document.addEventListener("turbo:load", function pauseNotification() {
        const button = document.querySelector("[data-controller='flash'][role='status'] button[aria-label='Dismiss notification']");
        if (!button) return;

        button.focus({ preventScroll: true });
        document.removeEventListener("turbo:load", pauseNotification);
      });
    JS
    fill_in "Prompt", with: "Find food support"
    click_button "Start new chat"
    expect(page).to have_current_path(%r{\A/chats/\d+\z}, wait: 10)
    expect(page).to have_field("Message", wait: 10)
    expect(page).to have_css("[data-controller='flash'][role='status']", text: "Chat was successfully created.")
  end

  it "overlays a success notification without moving the workspace and can be closed" do
    start_conversation

    navigation = find("nav[aria-label='Main navigation']")
    expect(find("main").evaluate_script("this.getBoundingClientRect().top"))
      .to eq(navigation.evaluate_script("this.getBoundingClientRect().bottom"))
    expect(find("[aria-label='Notifications']").style("position")["position"]).to eq("fixed")
    expect(find("#new_message").evaluate_script("this.getBoundingClientRect().bottom <= window.innerHeight")).to be(true)

    find("button[aria-label='Dismiss notification']").click

    expect(page).not_to have_css("[data-controller='flash']")
    expect(page).to have_field("Message")
  end

  it "dismisses a success notification automatically" do
    start_conversation
    find_field("Message").click

    expect(page).not_to have_css("[data-controller='flash']", wait: 8)
    expect(page).to have_field("Message")
  end

  it "does not restore a previous success notification when navigating back" do
    start_conversation
    conversation_path = page.current_path

    within("nav[aria-label='Main navigation']") { click_link "Chat", exact: true }
    expect(page).to have_current_path(new_chat_path)
    page.go_back

    expect(page).to have_current_path(conversation_path)
    expect(page).not_to have_css("[data-controller='flash']")
  end

  it "shows important errors with an accessible manual close control" do
    other_user = User.create!(email: "other-notifications@example.com", password: "password123")
    private_chat = other_user.chats.create!

    visit chat_path(private_chat)

    expect(page).to have_css("[data-controller='flash'][role='alert']", text: "You are not authorized to perform this action")
    find("button[aria-label='Dismiss notification']").click
    expect(page).not_to have_css("[data-controller='flash']")
  end

  it "keeps notifications below the shared header for members and admins on mobile and desktop" do
    [false, true].each do |admin|
      user.update!(admin: admin)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
      start_conversation

      navigation = find("nav[aria-label='Main navigation']")
      notification = find("[aria-label='Notifications']")
      expect(notification.evaluate_script("this.getBoundingClientRect().top"))
        .to be >= navigation.evaluate_script("this.getBoundingClientRect().bottom")

      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      expect(notification.evaluate_script("this.getBoundingClientRect().top"))
        .to be >= navigation.evaluate_script("this.getBoundingClientRect().bottom")
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
