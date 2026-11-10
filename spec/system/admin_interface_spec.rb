require "rails_helper"

RSpec.describe "Administration interface", type: :system do
  let(:admin) { User.create!(email: "admin-interface@example.com", password: "password123", admin: true) }
  let(:model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:source) { Source.create!(name: "Community support directory", source_type: "html", url: "https://example.com/#{"community-resources-" * 12}") }
  let(:document) { source.documents.create!(title: "Harbour community support", content: "Local meals and community services.", metadata: {city: "Victoria"}) }

  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
    login_as(admin, scope: :user)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1280, 900)
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
    administration = find("[aria-label='Administration']")
    administration.all("a").each do |link|
      expect(link.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
      expect(link.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
    end
    models_link = administration.find_link("Models", exact: true)
    expect(models_link.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
    models_link.click
    expect(page).to have_current_path(models_path)
    expect(page).to have_css("[aria-label='Administration'] a[aria-current='page']", text: "Models")
  end

  it "contains wide management tables and keeps model details reachable on a phone" do
    User.create!(email: "#{"long-account-name-" * 6}@example.com", password: "password123")
    Report.create!(document: document, user: admin, reason: "out of date", details: "Please check the listed opening hours.")
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 844, deviceScaleFactor: 1, mobile: true)

    {users_path => "User accounts", reports_path => "Reported resources", models_path => "Available models"}.each do |path, label|
      visit path

      expect(page).to have_css("[role='region'][aria-label='#{label}'][tabindex='0']")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end

    within("[aria-label='Available models']") { click_link model.name }
    expect(page).to have_current_path(model_path(model.id, provider: model.provider))
    expect(page).to have_css("h1", text: model.name)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  end

  it "keeps long source addresses within the phone layout" do
    document
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 844, deviceScaleFactor: 1, mobile: true)
    visit sources_path

    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    within("main") { click_link source.name }
    expect(page).to have_current_path(source_path(source))
    expect(page).to have_content(document.title)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  end
end
