require "rails_helper"

RSpec.describe "Conversation scrolling", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
    10.times { |index| chat.messages.create!(role: "user", content: "Earlier question #{index}\n" * 8) }
    reply
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1280, 900)
  end

  let(:user) { User.create!(email: "scrolling@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Local support") }
  let(:reply) { chat.messages.create!(role: "assistant", content: "The latest answer.") }

  def visit_conversation
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    expect(page).to have_css("[data-chat-scroll-target='viewport']") { |element| at_bottom?(element) }
  end

  def viewport
    find("[data-chat-scroll-target='viewport']")
  end

  def at_bottom?(element)
    element.evaluate_script("this.scrollHeight - this.clientHeight - this.scrollTop <= 2")
  end

  it "opens an existing conversation at the latest message" do
    visit_conversation

    expect(viewport.evaluate_script("this.scrollTop")).to be > 0
    expect(page).not_to have_button("Jump to latest")
    expect(find_field("Message").evaluate_script("this.getBoundingClientRect().bottom <= window.innerHeight")).to be(true)
  end

  it "follows new streamed content while reading at the bottom" do
    visit_conversation
    previous_height = viewport.evaluate_script("this.scrollHeight")

    reply.broadcast_append_chunk("\n\nAnother paragraph in the answer. " * 60)

    expect(page).to have_css("[data-chat-scroll-target='viewport']") do |element|
      element.evaluate_script("this.scrollHeight") > previous_height && at_bottom?(element)
    end
    expect(page).not_to have_button("Jump to latest")
  end

  it "keeps following when content growth also emits a native scroll event" do
    visit_conversation
    viewport.execute_script(<<~JS)
      const paragraph = document.createElement("p");
      paragraph.textContent = "New content below the previous bottom";
      paragraph.style.height = "300px";
      document.querySelector("[data-chat-scroll-target='content']").append(paragraph);
      this.dispatchEvent(new Event("scroll"));
    JS

    expect(page).to have_css("[data-chat-scroll-target='viewport']") { |element| at_bottom?(element) }
    expect(page).not_to have_button("Jump to latest")
  end

  it "does not resume from a wheel gesture that did not scroll the conversation" do
    visit_conversation
    answer = find("#message_#{reply.id} .assistant-markdown")
    answer.click
    position = viewport.evaluate_script("this.scrollTop")
    # A wheel gesture inside a nested reference scroller bubbles to the outer
    # viewport even when it does not move that viewport.
    answer.execute_script('this.dispatchEvent(new WheelEvent("wheel", {deltaY: 120, bubbles: true}))')
    reply.broadcast_append_chunk("\n\nNew content while reading the answer. " * 40)

    expect(page).to have_button("Jump to latest")
    expect(viewport.evaluate_script("this.scrollTop")).to be_within(1).of(position)
  end

  it "preserves the reading position and offers a jump when content arrives below" do
    visit_conversation
    viewport.execute_script("this.scrollTop = 0")
    expect(page).to have_css("[data-chat-scroll-target='viewport']") { |element| element.evaluate_script("this.scrollTop === 0") }
    # Deliver the position change before streaming rather than racing the queued
    # native scroll event in this browser-driven test.
    viewport.execute_script('this.dispatchEvent(new Event("scroll"))')

    reply.broadcast_append_chunk("\n\nNew information below the current reading position. " * 40)

    expect(page).to have_button("Jump to latest")
    expect(viewport.evaluate_script("this.scrollTop")).to eq(0)
    click_button "Jump to latest"
    expect(page).to have_css("[data-chat-scroll-target='viewport']") { |element| at_bottom?(element) }
    expect(page).not_to have_button("Jump to latest")
    expect(page.evaluate_script("document.activeElement.getAttribute('data-chat-scroll-target')")).to eq("viewport")

    previous_height = viewport.evaluate_script("this.scrollHeight")
    reply.broadcast_append_chunk("\n\nThe answer continues. " * 40)
    expect(page).to have_css("[data-chat-scroll-target='viewport']") do |element|
      element.evaluate_script("this.scrollHeight") > previous_height && at_bottom?(element)
    end
  end

  it "resumes following when the reader scrolls back to the bottom" do
    visit_conversation
    viewport.execute_script('this.scrollTop = 0; this.dispatchEvent(new Event("scroll"))')
    reply.broadcast_append_chunk("\n\nNew details. " * 40)
    expect(page).to have_button("Jump to latest")

    viewport.execute_script('this.scrollTop = this.scrollHeight; this.dispatchEvent(new Event("scroll"))')
    expect(page).not_to have_button("Jump to latest")
    previous_height = viewport.evaluate_script("this.scrollHeight")
    reply.broadcast_append_chunk("\n\nMore details. " * 40)

    expect(page).to have_css("[data-chat-scroll-target='viewport']") do |element|
      element.evaluate_script("this.scrollHeight") > previous_height && at_bottom?(element)
    end
  end

  it "follows composer resizing without interrupting someone reading earlier messages" do
    visit_conversation
    find_field("Message").execute_script(<<~JS, "A line in a draft\n" * 12)
      this.value = arguments[0];
      this.dispatchEvent(new InputEvent("input", {bubbles: true, inputType: "insertFromPaste", data: arguments[0]}));
    JS
    expect(page).to have_css("[data-chat-scroll-target='viewport']") { |element| at_bottom?(element) }

    viewport.execute_script('this.scrollTop = 0; this.dispatchEvent(new Event("scroll"))')
    fill_in "Message", with: "Short draft"

    expect(viewport.evaluate_script("this.scrollTop")).to eq(0)
    expect(page).not_to have_button("Jump to latest")
  end

  it "keeps the jump control and composer reachable on mobile" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    visit_conversation
    viewport.execute_script('this.scrollTop = 0; this.dispatchEvent(new Event("scroll"))')
    reply.broadcast_append_chunk("\n\nA mobile update. " * 40)

    expect(page).to have_button("Jump to latest")
    expect(find_button("Jump to latest").evaluate_script("this.getBoundingClientRect().bottom <= window.innerHeight")).to be(true)
    expect(find_field("Message").evaluate_script("this.getBoundingClientRect().bottom <= window.innerHeight")).to be(true)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  end
end
