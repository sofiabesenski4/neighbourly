require "rails_helper"

RSpec.describe "Reporting resources on mobile", type: :system do
  let(:user) { User.create!(email: "mobile-report@example.com", password: "password123") }
  let(:source) { Source.create!(name: "Victoria Community Directory", source_type: "api", url: "https://example.com/resources") }
  let(:document) { source.documents.create!(title: "HarbourCommunityKitchen" * 5, content: "Community meals and support.") }
  let(:chat) { user.chats.create!(title: "Local meals") }

  before do
    driven_by(:selenium_chrome_headless)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
    reply = chat.messages.create!(role: "assistant", content: "Try the community kitchen.")
    reply.rag_documents << document
    login_as(user, scope: :user)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.current_window.resize_to(1280, 900)
  end

  [[320, 740], [844, 390]].each do |width, height|
    it "can cancel and submit a report at #{width} by #{height}" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: true)
      visit chat_path(chat)
      fill_in "Message", with: "An unsent follow-up question"
      find("summary", text: "References").click
      expect(find_button("Report", exact: true).evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      click_button "Report", exact: true

      dialog = find("dialog[open]")
      expect(dialog.evaluate_script("this.getBoundingClientRect().left >= 15 && this.getBoundingClientRect().right <= window.innerWidth - 15")).to be(true)
      expect(dialog.evaluate_script("this.getBoundingClientRect().top >= 15 && this.getBoundingClientRect().bottom <= window.innerHeight - 15")).to be(true)
      within(dialog) do
        expect(find_field("Additional details (optional)").evaluate_script("parseFloat(getComputedStyle(this).fontSize)")).to be >= 16
        expect(find_field("Out of date").ancestor("label").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
        choose "Out of date"
        fill_in "Additional details (optional)", with: "Please check the opening hours."
        click_button "Cancel"
      end
      expect(page).not_to have_css("dialog[open]")
      expect(page).to have_field("Message", with: "An unsent follow-up question")
      expect(Report.count).to eq(0)

      click_button "Report", exact: true
      within("dialog[open]") do
        submit = find_button("Submit Report")
        expect(submit.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
        submit.click
      end

      expect(page).to have_content("Thank you. Your report has been submitted.")
      expect(Report.last).to have_attributes(document_id: document.id, user_id: user.id, reason: "out of date", details: "Please check the opening hours.")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end
  end
end
