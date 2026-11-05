require "rails_helper"

RSpec.describe "Landing page", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
  end

  it "introduces community support without overflowing the desktop layout" do
    page.current_window.resize_to(1280, 900)
    visit root_path

    within("main") do
      expect(page).to have_css("h1", text: "What would help you today?", count: 1)
      expect(page).to have_content("Victoria, BC")
      expect(page).to have_content("Find food, shelter, health care, and everyday support nearby.")
    end

    hero = find("section[aria-labelledby='home-heading']")
    expect(hero.evaluate_script("this.getBoundingClientRect().width")).to be <= 808
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  end

  it "keeps the welcome readable within a narrow phone screen" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit root_path

    hero = find("section[aria-labelledby='home-heading']")
    expect(hero).to have_css("h1", text: "What would help you today?")
    expect(hero).to have_content("Victoria, BC")
    expect(hero).to have_content("Find food, shelter, health care, and everyday support nearby.")

    hero.all("h1, p").each do |element|
      expect(element.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
    end
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
