require "rails_helper"

# Covers answering the questionnaire as a person does: in Chrome, at phone width, and
# without JavaScript. What each answer finds is covered by the model spec.
RSpec.describe "Questionnaire", type: :system do
  before do
    meals = Category.create!(name: "Meals")
    shelters = Category.create!(name: "Shelters")
    source = Source.create!(name: "Local guide", source_type: "csv")
    source.services.create!(name: "Soup kitchen", categories: [meals])
    source.services.create!(name: "Shelter", categories: [shelters])
  end

  context "in Chrome" do
    before { driven_by(:selenium_chrome_headless) }

    after { page.current_window.resize_to(1280, 900) }

    it "finds services for the chosen need, keeping the answer out of the URL" do
      visit find_help_for_myself_path
      check "Food"
      click_button "Next"

      expect(page).to have_content("Soup kitchen")
      expect(page).not_to have_content("Shelter")
      expect(page.current_url).to end_with("/find-help/myself")
    end

    it "starts at the question, and can be answered with the keyboard" do
      visit find_help_for_myself_path
      expect(page).to have_css("h1:focus", text: "What do you need help with?")

      page.active_element.send_keys(:tab, :space)
      expect(page).to have_checked_field("Food")
      page.active_element.send_keys(:enter)

      expect(page).to have_content("Soup kitchen")
    end

    it "fits a phone without sideways scrolling, with large touch targets" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 740, deviceScaleFactor: 1, mobile: true)
      visit find_help_for_myself_path
      expect(page).to have_css("fieldset label", minimum: 2)

      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 320
      heights = page.evaluate_script("[...document.querySelectorAll('fieldset label, main form button')].map(e => e.getBoundingClientRect().height)")
      expect(heights).to all(be >= 44)
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  # rack_test runs no JavaScript.
  it "works without JavaScript" do
    driven_by(:rack_test)

    visit find_help_for_myself_path
    check "A place to stay"
    click_button "Next"

    expect(page.body).to eq("Shelter")
  end
end
