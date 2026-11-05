require "rails_helper"

RSpec.describe "Conversation options", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1280, 900)
  end

  let(:user) { User.create!(email: "options@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Meal options") }

  def open_options(conversation, container = "#chat_sidebar")
    row = find("#{container} [data-chat-row='#{conversation.id}']")
    row.hover unless container == "#chat_drawer"
    row.find("button[aria-haspopup='menu']").click
    expect(row).to have_css("[popover]:popover-open")
    row
  end

  it "deletes the open conversation after confirmation" do
    visit chat_path(chat)
    row = open_options(chat)
    accept_confirm { row.click_button "Delete conversation" }

    expect(page).to have_current_path(new_chat_path)
    expect(Chat.exists?(chat.id)).to be(false)
  end

  it "keeps the conversation when deletion is cancelled" do
    visit chat_path(chat)
    row = open_options(chat)
    dismiss_confirm { row.click_button "Delete conversation" }

    expect(page).to have_current_path(chat_path(chat))
    expect(Chat.exists?(chat.id)).to be(true)
  end

  it "closes the menu when the dots are clicked again or outside is clicked" do
    visit chat_path(chat)
    row = open_options(chat)
    row.find("button[aria-haspopup='menu']").click
    expect(row).not_to have_css("[popover]:popover-open")

    row = open_options(chat)
    find("h1").click
    expect(row).not_to have_css("[popover]:popover-open")
    expect(Chat.exists?(chat.id)).to be(true)
  end

  it "preserves the open conversation and draft when another conversation is deleted" do
    other_chat = user.chats.create!(title: "Shelter options")
    visit chat_path(chat)
    fill_in "Message", with: "An unsent question"
    row = open_options(other_chat)
    accept_confirm { row.click_button "Delete conversation" }

    expect(page).not_to have_css("[data-chat-row='#{other_chat.id}']", visible: :all)
    expect(page).to have_current_path(chat_path(chat))
    expect(page).to have_field("Message", with: "An unsent question")
  end

  it "supports keyboard access and Escape without deleting" do
    visit chat_path(chat)
    row = find("#chat_sidebar [data-chat-row='#{chat.id}']")
    link = row.find_link("Meal options")
    # Establish the tab sequence's starting point before the composer can autofocus.
    link.execute_script("this.focus()")
    expect(row).to have_css("a:focus", text: "Meal options")
    link.send_keys(:tab)
    expect(row).to have_css("button[aria-haspopup='menu']:focus")
    page.driver.browser.switch_to.active_element.send_keys(:enter)
    expect(row).to have_css("[popover]:popover-open")
    expect(row).to have_css("[role='menuitem']:focus")
    row.find_button("Delete conversation").send_keys(:escape)
    expect(row).not_to have_css("[popover]:popover-open")
    expect(row).to have_css("button[aria-expanded='false']:focus")
    expect(Chat.exists?(chat.id)).to be(true)
  end

  it "makes conversation actions available in the mobile drawer without hover" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    visit chat_path(chat)
    find("button[aria-label='Open conversations']").click
    row = find("#chat_drawer [data-chat-row='#{chat.id}']")
    expect(row.find("button[aria-haspopup='menu']").style("opacity")["opacity"]).to eq("1")
    row = open_options(chat, "#chat_drawer")
    accept_confirm { row.click_button "Delete conversation" }

    expect(page).to have_current_path(new_chat_path)
    expect(Chat.exists?(chat.id)).to be(false)
  end
end
