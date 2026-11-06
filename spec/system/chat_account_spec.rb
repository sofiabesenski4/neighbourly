require "rails_helper"

RSpec.describe "Chat account navigation", type: :system do
  before { driven_by(:selenium_chrome_headless) }

  it "shows the signed-in email beside Sign out in the workspace" do
    user = User.create!(email: "account@example.com", password: "password123")
    login_as(user, scope: :user)
    page.current_window.resize_to(1280, 900)

    visit new_chat_path

    within("nav[aria-label='Main navigation']") do
      expect(page).to have_text(user.email)
      expect(page).to have_button("Sign out")
    end
  end

  it "keeps both tabs and sign-out available on a narrow chat screen" do
    user = User.create!(email: "mobile-account@example.com", password: "password123")
    login_as(user, scope: :user)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit new_chat_path

    within("nav[aria-label='Main navigation']") do
      expect(page).to have_link("neighbourly", href: root_path)
      expect(page).to have_link("Chat", href: new_chat_path)
      expect(page).to have_link("Printout", href: new_flyer_path)
      all("a, button").each do |control|
        expect(control.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
        expect(control.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      end
      click_button "Sign out"
    end
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("Start chat", disabled: true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
