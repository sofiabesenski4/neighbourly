require "rails_helper"
require "support/two_question_questionnaire"

# Covers answering the questionnaire as a person does: in Chrome, at phone width, and
# without JavaScript. What each answer finds is covered by the model spec.
#
# Every button loads a whole new page. Looking for an element while Chrome swaps pages can
# fail with "Node with given id does not belong to the document", which Capybara doesn't
# retry. So after each button these wait for the new page's title, which involves no element.
RSpec.describe "Questionnaire", type: :system do
  include TwoQuestionQuestionnaire

  before do
    meals = Category.create!(name: "Meals")
    shelters = Category.create!(name: "Shelters")
    source = Source.create!(name: "Local guide", source_type: "csv")
    source.services.create!(name: "Soup kitchen", categories: [meals])
    source.services.create!(name: "Shelter", categories: [shelters])
  end

  def expect_question(number)
    expect(page).to have_title("Question #{number} of 2 - Find help", exact: true)
  end

  # The temporary plain list has no title.
  def expect_results
    expect(page).to have_title("", exact: true)
  end

  context "in Chrome" do
    before { driven_by(:selenium_chrome_headless) }

    after { page.current_window.resize_to(1280, 900) }

    it "finds services for the chosen need, keeping the answer out of the URL" do
      visit find_help_for_myself_path
      check "Food"
      click_button "Next"

      expect_results
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

      expect_results
      expect(page).to have_content("Soup kitchen")
    end

    it "fits a phone without sideways scrolling, with large touch targets" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 740, deviceScaleFactor: 1, mobile: true)
      visit find_help_for_myself_path
      expect(page).to have_css("fieldset label", minimum: 2)

      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 320
      heights = page.evaluate_script("[...document.querySelectorAll('fieldset label, main form button, main form a')].map(e => e.getBoundingClientRect().height)")
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

      expect(page.body.lines(chomp: true))
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
