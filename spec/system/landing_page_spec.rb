require "rails_helper"

RSpec.describe "Landing page", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
  end

  it "supports keyboard navigation from the landing page into guest chat" do
    page.current_window.resize_to(1280, 900)
    visit root_path

    navigation = find("nav[aria-label='Main navigation']")
    expect(navigation).to have_link("neighbourly", href: root_path)
    expect(navigation).to have_link("Chat", href: new_chat_path)
    expect(navigation).to have_link("Printout", href: new_flyer_path)
    expect(navigation).to have_link("Sign in", href: new_user_session_path)
    expect(navigation).not_to have_link("Saved")
    expect(navigation).to have_no_css("a[aria-current], a.bg-sage-100")

    navigation.find_link("neighbourly", exact: true).send_keys(:tab)
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Chat")
    navigation.find_link("Chat", exact: true).send_keys(:enter)
    expect(page).to have_current_path(new_chat_path)
    expect(page).to have_content("Guest chat")
  end

  it "keeps both navigation links visible on a narrow phone screen" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit root_path

    navigation = find("nav[aria-label='Main navigation']")
    expect(navigation).to have_link("neighbourly", href: root_path)
    expect(navigation).to have_link("Chat", href: new_chat_path)
    expect(navigation).to have_link("Printout", href: new_flyer_path)
    expect(navigation).to have_link("Sign in", href: new_user_session_path)
    expect(navigation).not_to have_button("Open main menu")

    navigation.all("a").each do |link|
      expect(link.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
      expect(link.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
    end
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "lets signed-in visitors sign out from the landing navigation" do
    user = User.create!(email: "landing-account@example.com", password: "password123")
    login_as(user, scope: :user)
    page.current_window.resize_to(1280, 900)
    visit root_path

    within("nav[aria-label='Main navigation']") do
      expect(page).to have_content(user.email)
      click_button "Sign out", exact: true
    end

    expect(page).to have_current_path(root_path)
    expect(find("nav[aria-label='Main navigation']")).to have_link("Sign in", href: new_user_session_path)
  end

  it "introduces community support without overflowing the desktop layout" do
    page.current_window.resize_to(1280, 900)
    visit root_path

    within("main") do
      expect(page).to have_css("h1", text: "What would help you today?", count: 1)
      expect(page).to have_content("Victoria, BC")
      expect(page).to have_content("Find food, shelter, health care, and everyday support nearby.")
    end

    composer = find("section[aria-label='Start a chat']")
    printout = find("section[aria-labelledby='printout-heading']")
    link = printout.find_link("Create printout")
    expect(link.evaluate_script("getComputedStyle(this).backgroundColor"))
      .to eq(composer.find("button[type='submit']").evaluate_script("getComputedStyle(this).backgroundColor"))
    features = find("section[aria-labelledby='community-heading']")
    expect(printout.evaluate_script("this.getBoundingClientRect().top"))
      .to be >= composer.evaluate_script("this.getBoundingClientRect().bottom")
    expect(features.evaluate_script("this.getBoundingClientRect().top"))
      .to be >= printout.evaluate_script("this.getBoundingClientRect().bottom")

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

    printout = find("section[aria-labelledby='printout-heading']")
    link = printout.find_link("Create printout", href: new_flyer_path)
    expect(link.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
    expect(link.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)

    hero.all("h1, p").each do |element|
      expect(element.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
    end
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "presents three readable feature columns on desktop" do
    page.current_window.resize_to(1280, 900)
    visit root_path

    features = find("section[aria-labelledby='community-heading']")
    articles = features.all("article", count: 3)
    expect(articles.map { |article| article.find("h3").text })
      .to eq(["Ask in plain language", "Local organizations", "Community moderated"])
    expect(find("section[aria-labelledby='printout-heading']").evaluate_script("this.getBoundingClientRect().bottom"))
      .to be <= page.evaluate_script("window.innerHeight")
    expect(features).to have_content("Describe what you need and get relevant results from community resources.")
    expect(features).not_to have_content("verified")

    expect(articles.map { |article| article.evaluate_script("this.getBoundingClientRect().top") }.uniq.length).to eq(1)
    positions = articles.map { |article| article.evaluate_script("this.getBoundingClientRect().left") }
    expect(positions).to eq(positions.sort.uniq)
    articles.each do |article|
      expect(article.find("p").evaluate_script("getComputedStyle(this).textAlign")).to eq("left")
    end
    page.scroll_to(:bottom)
    expect(articles.last.find("p").evaluate_script("this.getBoundingClientRect().bottom"))
      .to be <= page.evaluate_script("window.innerHeight")
  end

  it "stacks the features within a narrow phone screen" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit root_path

    features = find("section[aria-labelledby='community-heading']")
    articles = features.all("article", count: 3)
    positions = articles.map { |article| article.evaluate_script("this.getBoundingClientRect().top") }
    expect(positions).to eq(positions.sort.uniq)
    expect(find("section[aria-labelledby='printout-heading']").evaluate_script("this.getBoundingClientRect().bottom"))
      .to be <= page.evaluate_script("window.innerHeight")
    articles.each do |article|
      expect(article.find("h3")).to be_visible
      expect(article.find("p").evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
    end
    page.scroll_to(:bottom)
    expect(articles.last.find("p").evaluate_script("this.getBoundingClientRect().bottom"))
      .to be <= page.evaluate_script("window.innerHeight")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
