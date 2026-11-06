require "rails_helper"

RSpec.describe "Chat account navigation", type: :system do
  before { driven_by(:selenium_chrome_headless) }

  it "keeps the shared links usable after a failed sign-in on a narrow screen" do
    user = User.create!(email: "sign-in-header@example.com", password: "password123")
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit root_path
    find("nav").click_link "Sign in"
    expect(page).to have_current_path(new_user_session_path)
    expect(page).to have_link("Sign up", href: new_user_registration_path)
    expect(page).to have_link("Forgot your password?", href: new_user_password_path)

    fill_in "Email address", with: user.email
    fill_in "Password", with: "wrong-password"
    click_button "Sign in", exact: true
    expect(page).to have_content("Invalid email or password.")
    alert = find("[role='alert']", text: "Invalid email or password.")
    expect(alert.evaluate_script("this.getBoundingClientRect().top >= document.querySelector('nav').getBoundingClientRect().bottom")).to be(true)

    within("nav[aria-label='Main navigation']") do
      expect(page).to have_link("neighbourly", href: root_path)
      expect(page).to have_link("Chat", href: new_chat_path)
      expect(page).to have_link("Printout", href: new_flyer_path)
      expect(page).to have_link("Sign in", href: new_user_session_path)
      all("a").each do |link|
        expect(link.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
      end
      click_link "Chat"
    end
    expect(page).to have_current_path(new_chat_path)
    expect(page).to have_content("Guest chat")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

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
