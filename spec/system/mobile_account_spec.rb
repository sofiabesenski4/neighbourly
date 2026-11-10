require "rails_helper"

RSpec.describe "Mobile account forms", type: :system do
  let!(:user) { User.create!(email: "mobile-account@example.com", password: "password123") }

  before do
    driven_by(:selenium_chrome_headless)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    ActionMailer::Base.deliveries.clear
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.current_window.resize_to(1280, 900)
  end

  def expect_usable_fields
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    all(".account-form input:not([type='hidden']):not([type='checkbox']):not([type='submit'])").each do |field|
      expect(field.evaluate_script("parseFloat(getComputedStyle(this).fontSize)")).to be >= 16
      expect(field.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      expect(field.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
    end
    expect(find(".account-form input[type='submit']").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
  end

  [[320, 740], [844, 390]].each do |width, height|
    it "signs in at #{width} by #{height}" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: true)
      visit new_user_session_path
      expect_usable_fields
      expect(find_link("Forgot your password?").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      fill_in "Email address", with: user.email
      fill_in "Password", with: "password123"
      click_button "Sign in"

      expect(page).to have_button("Sign out")
    end

    it "requests and completes a password reset at #{width} by #{height}" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: true)
      visit new_user_password_path
      expect_usable_fields
      fill_in "Email", with: user.email
      click_button "Send me password reset instructions"

      expect(page).to have_content("You will receive an email with instructions")
      mail = ActionMailer::Base.deliveries.last
      reset_url = Nokogiri::HTML(mail.body.decoded).at_css("a")["href"]
      visit URI(reset_url).request_uri
      expect(page).to have_css("h1", text: "Change your password")
      expect_usable_fields
      fill_in "New password", with: "updated-password123"
      fill_in "Confirm new password", with: "updated-password123"
      click_button "Change my password"

      expect(page).to have_content("Your password has been changed successfully")
      expect(user.reload.valid_password?("updated-password123")).to be(true)
    end
  end

  it "preserves registration feedback and can create an account on a narrow phone" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 740, deviceScaleFactor: 1, mobile: true)
    visit new_user_registration_path
    expect_usable_fields
    fill_in "Email address", with: "new-mobile-account@example.com"
    fill_in "Password", with: "a", exact: true
    fill_in "Confirm password", with: "a"
    click_button "Sign up"

    expect(page).to have_css("[role='alert']", text: "Password is too short")
    expect_usable_fields
    fill_in "Password", with: "password456", exact: true
    fill_in "Confirm password", with: "password456"
    click_button "Sign up"

    expect(page).to have_button("Sign out")
    expect(User.find_by(email: "new-mobile-account@example.com")).to be_present
  end

  it "updates account details on a narrow phone" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 740, deviceScaleFactor: 1, mobile: true)
    login_as(user, scope: :user)
    visit edit_user_registration_path
    expect_usable_fields
    fill_in "Email", with: "updated-mobile-account@example.com"
    fill_in "Current password", with: "password123"
    click_button "Update"

    expect(page).to have_content("Your account has been updated successfully")
    expect(user.reload.email).to eq("updated-mobile-account@example.com")
  end
end
