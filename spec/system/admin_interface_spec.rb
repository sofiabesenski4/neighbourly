require "rails_helper"

RSpec.describe "Administration interface", type: :system do
  let(:admin) { User.create!(email: "admin-interface@example.com", password: "password123", admin: true) }
  let(:model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }

  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
    login_as(admin, scope: :user)
  end

  it "moves between administration and support pages through the shared header" do
    visit users_path
    expect(find("nav[aria-label='Main navigation']")).to have_link("neighbourly", href: root_path)

    {"Sources" => sources_path, "Moderation" => reports_path, "Models" => models_path}.each do |label, destination|
      within("[aria-label='Administration']") { click_link label, exact: true }
      expect(page).to have_current_path(destination)
      expect(page).to have_css("[aria-label='Administration'] a[aria-current='page']", text: label)
    end

    within("nav[aria-label='Main navigation']") { click_link "Chat", exact: true }
    expect(page).to have_current_path(new_chat_path)
    expect(page).to have_css("nav a[aria-current='page']", text: "Chat")
    expect(page).not_to have_css("[aria-label='Administration'] a[aria-current='page']")
  end

  it "keeps administration links reachable on a narrow phone screen" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 844, deviceScaleFactor: 1, mobile: true)
    visit users_path

    within("nav[aria-label='Main navigation']") do
      expect(page).to have_link("Chat", href: new_chat_path)
      expect(page).to have_link("Printout", href: new_flyer_path)
      expect(page).to have_button("Sign out")
    end
    models_link = find("[aria-label='Administration']").find_link("Models", exact: true)
    expect(models_link.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
    models_link.click
    expect(page).to have_current_path(models_path)
    expect(page).to have_css("[aria-label='Administration'] a[aria-current='page']", text: "Models")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
