require "rails_helper"
require "pdf/reader"
require "support/two_question_questionnaire"

# Covers answering the questionnaire as a person does: in Chrome, at phone width, and
# without JavaScript. What each answer finds is covered by the model spec.
#
# Every button loads a whole new page. Looking for an element while Chrome swaps pages can
# fail with "Node with given id does not belong to the document", which Capybara doesn't
# retry. So after each button these wait for the new page's title, which involves no element.
RSpec.describe "Questionnaire", type: :system do
  include TwoQuestionQuestionnaire

  # The first contexts use the real questions: needs, then location. The lookup is faked.
  before do
    meals = Category.create!(name: "Meals")
    shelters = Category.create!(name: "Shelters")
    source = Source.create!(name: "Local guide", source_type: "csv")
    source.services.create!(name: "Far kitchen", categories: [meals], address_attributes: {lat: 48.50, lng: -123.36})
    source.services.create!(name: "Near kitchen", categories: [meals], address_attributes: {lat: 48.421, lng: -123.36})
    source.services.create!(name: "Shelter", categories: [shelters])
    allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.42, lng: -123.36))
  end

  def expect_question(number)
    expect(page).to have_title("Question #{number} of 2 - Find help", exact: true)
  end

  def expect_results
    expect(page).to have_title("Printout", exact: true)
    expect(page).to have_css('nav[aria-label="Printout view"] [aria-current="page"]', text: "Answer a few questions")
  end

  def result_names
    all("main article h3").map(&:text)
  end

  context "in Chrome" do
    before { driven_by(:selenium_chrome_headless) }

    after { page.current_window.resize_to(1280, 900) }

    it "checks and clears the choices beneath a category group" do
      Category.create!(name: "Food Banks")
      visit find_help_for_myself_path

      within("[role='group'][aria-label='Food and meals']") do
        check "Food and meals"
        expect(page).to have_checked_field("Food Banks")
        expect(page).to have_checked_field("Meals", exact: true)

        uncheck "Meals", exact: true
        expect(page).to have_unchecked_field("Food and meals")
        expect(page).to have_checked_field("Food Banks")

        check "Food and meals"
        uncheck "Food and meals"
        expect(page).to have_unchecked_field("Food Banks")
        expect(page).to have_unchecked_field("Meals", exact: true)
      end
      expect(page).to have_unchecked_field("Housing Services")
    end

    it "finds services for the chosen need, closest first, keeping the answers out of the URL" do
      visit new_flyer_path
      click_link "Answer a few questions"
      expect_question 1
      check "Food and meals"
      click_button "Next"
      expect_question 2
      fill_in "Enter a place", with: "919 Pandora Ave"
      click_button "Next"

      expect_results
      expect(result_names).to eq(["Near kitchen", "Far kitchen"])
      expect(page).not_to have_content("Shelter")
      expect(page.current_url).to end_with("/find-help/myself")
      find("article", text: "Far kitchen").uncheck("Include")
      find("article", text: "Near kitchen").uncheck("Include")
      expect(page).to have_button("Generate printout", disabled: true)
      find("article", text: "Near kitchen").check("Include")
      printout = window_opened_by { click_button "Generate printout" }
      expect(page).to have_link("Open printout", href: /\Ablob:/)
    ensure
      printout&.close
    end

    it "goes from the home page to the results" do
      visit root_path
      click_link "For myself"
      expect_question 1
      expect(page).to have_css("h1:focus", text: "What do you need help with?")
      check "Food and meals"
      click_button "Next"
      expect_question 2
      fill_in "Enter a place", with: "919 Pandora Ave"
      click_button "Next"

      expect_results
      expect(result_names).to eq(["Near kitchen", "Far kitchen"])
      expect(page).not_to have_content("Shelter")
    end

    it "sends someone looking for another person from the home page to chat" do
      visit root_path
      click_link "For someone else"
      expect(page).to have_title("Find help for someone else", exact: true)
      click_link "Ask in chat"

      expect(page).to have_current_path(new_chat_path)
      expect(page).to have_content("Guest chat")
    end

    it "starts at the question, and can be answered with the keyboard" do
      visit find_help_for_myself_path
      expect(page).to have_css("h1:focus", text: "What do you need help with?")

      page.active_element.send_keys(:tab, :space)
      expect(page).to have_checked_field("Food and meals")
      page.active_element.send_keys(:enter)
      expect_question 2
      expect(page).to have_css("h1:focus", text: "Where are you?")

      # Past the "Use my location" button, to the text box.
      page.active_element.send_keys(:tab, :tab, "919 Pandora Ave", :enter)
      expect_results
      expect(result_names).to eq(["Near kitchen", "Far kitchen"])
    end

    # Uses Chrome's real location API and permission system. Chrome's developer tools set the
    # answers a person or device would give, since a test can't click the browser's own
    # permission prompt. The prompt itself isn't covered.
    context "with Use my location" do
      def set_location(setting, accuracy: 50)
        browser = page.driver.browser
        browser.execute_cdp("Browser.setPermission", permission: {name: "geolocation"}, setting: setting, origin: page.server_url)
        browser.execute_cdp("Emulation.setGeolocationOverride", latitude: 48.4201, longitude: -123.3602, accuracy: accuracy)
      end

      before do
        visit find_help_for_myself_path
        click_button "Next"
        expect_question 2
      end

      after do
        page.driver.browser.execute_cdp("Emulation.clearGeolocationOverride")
        page.driver.browser.execute_cdp("Browser.resetPermissions")
      end

      def hidden_value(field)
        find("input[name='questionnaire[answers][location][#{field}]']", visible: :all).value
      end

      it "waits for Next, then lists the closest services first without a lookup" do
        expect(Geocoder).not_to receive(:locate)
        set_location("granted")
        click_button "Use my location"

        expect(page).to have_css("[role='status']", text: "Using your location (accurate to about 50 m). Press Next to continue.")
        expect(hidden_value(:lat)).to eq("48.420")
        expect(hidden_value(:lng)).to eq("-123.360")
        expect(page).to have_title("Question 2 of 2 - Find help", exact: true)
        click_button "Next"

        expect_results
        expect(result_names).to eq(["Near kitchen", "Far kitchen", "Shelter"])
        expect(page.current_url).to end_with("/find-help/myself")
      end

      it "keeps the location when going back and forward" do
        set_location("granted")
        click_button "Use my location"
        expect(page).to have_css("[role='status']", text: "Using your location")
        click_button "Back"
        expect_question 1
        click_button "Next"

        expect_question 2
        expect(page).to have_css("[role='status']", text: "Using your location.")
        expect(hidden_value(:lat)).to eq("48.42")
      end

      it "warns when the location is rough" do
        set_location("granted", accuracy: 3000)
        click_button "Use my location"

        expect(page).to have_css("[role='status']", text: "may be off by about 3 km")
      end

      it "lets someone type a place when access is turned off" do
        set_location("denied")
        click_button "Use my location"

        expect(page).to have_css("[role='status']", text: "Location access is turned off")
        fill_in "Enter a place", with: "919 Pandora Ave"
        expect(page).to have_no_css("[role='status']")
        click_button "Next"
        expect_results
        expect(result_names).to eq(["Near kitchen", "Far kitchen", "Shelter"])
      end

      it "is replaced by a typed place" do
        expect(Geocoder).to receive(:locate).with("1 Fort St, Victoria, BC").and_return(GeoPoint.new(lat: 48.50, lng: -123.36))
        set_location("granted")
        click_button "Use my location"
        expect(page).to have_css("[role='status']", text: "Using your location")
        fill_in "Enter a place", with: "1 Fort St"

        expect(page).to have_no_css("[role='status']")
        expect(hidden_value(:device)).to eq("")
        click_button "Next"
        expect_results
        expect(result_names).to eq(["Far kitchen", "Near kitchen", "Shelter"])
      end
    end

    it "lets someone correct a place that can't be found" do
      allow(Geocoder).to receive(:locate).and_return(nil, GeoPoint.new(lat: 48.42, lng: -123.36))
      visit find_help_for_myself_path
      click_button "Next"
      expect_question 2
      fill_in "Enter a place", with: "Central Library"
      click_button "Next"

      expect(page).to have_title("Problem - Question 2 of 2 - Find help", exact: true)
      expect(page).to have_css("[role='alert']", text: "We couldn't find that place")
      expect(page).to have_field("Enter a place", with: "Central Library")
      fill_in "Enter a place", with: "735 Broughton St"
      click_button "Next"
      expect_results
      expect(page).to have_content("Near kitchen")
    end

    it "fits a phone without sideways scrolling, with large touch targets" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 740, deviceScaleFactor: 1, mobile: true)
      visit find_help_for_myself_path
      expect(page).to have_css("fieldset label", minimum: 2)

      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 320
      heights = page.evaluate_script("[...document.querySelectorAll('fieldset label, main form button, main form a')].map(e => e.getBoundingClientRect().height)")
      expect(heights).to all(be >= 44)
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 320

      click_button "Next"
      expect_question 2
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 320
      [find_field("Enter a place"), find_button("Use my location")].each do |control|
        expect(control.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      end
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  # rack_test runs no JavaScript.
  it "works without JavaScript" do
    driven_by(:rack_test)

    visit find_help_for_myself_path
    check "Food and meals"
    click_button "Next"
    fill_in "Enter a place", with: "919 Pandora Ave"
    click_button "Back"
    check "Housing Services"
    click_button "Next"
    expect(page).to have_field("Enter a place", with: "919 Pandora Ave")
    click_button "Next"

    expect_results
    expect(result_names).to eq(["Near kitchen", "Far kitchen", "Shelter"])
    find("article", text: "Shelter").uncheck("Include")
    check "Include extra details in printout"
    click_button "Generate printout"

    expect(page.response_headers["Content-Type"]).to include("application/pdf")
    pdf = PDF::Reader.new(StringIO.new(page.body))
    listings = pdf.pages.fetch(2).text
    expect(listings.scan(/\d+\.\s+(Near kitchen|Far kitchen|Shelter)\b/).flatten).to eq(["Near kitchen", "Far kitchen"])
    expect(listings).to include("Distance:")
  end

  context "with several questions" do
    before do
      Service.destroy_all
      Category.destroy_all
      use_two_questions
    end

    def go_through_the_chain
      visit find_help_for_myself_path
      check "Food"
      click_button "Next"
      expect_question 2
      choose "Our Place"
      click_button "Back"
      expect_question 1
      expect(page).to have_checked_field("Food")
      check "A place to stay"
      click_button "Next"
      expect_question 2
      expect(page).to have_checked_field("Our Place")
      click_button "Skip"
    end

    it "goes back, changes an answer and skips a question, without JavaScript" do
      driven_by(:rack_test)
      go_through_the_chain

      expect(result_names)
        .to eq(["Our Place beds", "Our Place meals", "The Mustard Seed beds", "The Mustard Seed meals"])
    end

    context "in Chrome" do
      before { driven_by(:selenium_chrome_headless) }

      it "goes back, changes an answer and skips a question" do
        go_through_the_chain

        expect_results
        expect(page).to have_content("The Mustard Seed beds")
        expect(page.current_url).to end_with("/find-help/myself")
      end

      it "presses Next when Enter is used on a later question, and starts at its heading" do
        visit find_help_for_myself_path
        check "Food"
        click_button "Next"
        expect_question 2
        expect(page).to have_css("h1:focus", text: "Who would you like to go to?")

        choose "Our Place"
        page.active_element.send_keys(:enter)

        expect_results
        expect(page).to have_content("Our Place meals")
        expect(page).not_to have_content("beds")
      end

      it "forgets every answer with Start over" do
        visit find_help_for_myself_path
        check "Food"
        click_button "Next"
        expect_question 2
        choose "Our Place"
        click_link "Start over"

        expect_question 1
        expect(page).to have_unchecked_field("Food")
        click_button "Next"
        expect_question 2
        expect(page).to have_unchecked_field("Our Place")
      end

      it "keeps no answers in the browser's storage" do
        visit find_help_for_myself_path
        check "Food"
        click_button "Next"
        expect_question 2

        stored = page.evaluate_script("JSON.stringify([{...localStorage}, {...sessionStorage}, document.cookie])")
        expect(stored).not_to include("food")
      end

      # Turbo makes the browser's Back ask for a fresh page. See docs/questionnaire-notes.md.
      it "returns to an unanswered first question with the browser's own Back button" do
        visit find_help_for_myself_path
        check "Food"
        click_button "Next"
        expect_question 2
        page.go_back

        expect_question 1
        expect(page).to have_unchecked_field("Food")
      end

      it "fits a phone without sideways scrolling, with large touch targets" do
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 740, deviceScaleFactor: 1, mobile: true)
        visit find_help_for_myself_path
        click_button "Next"
        expect_question 2
        expect(page).to have_button("Back")

        expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 320
        heights = page.evaluate_script("[...document.querySelectorAll('fieldset label, main form button, main form a')].map(e => e.getBoundingClientRect().height)")
        expect(heights).to all(be >= 44)
      ensure
        page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      end
    end
  end
end
