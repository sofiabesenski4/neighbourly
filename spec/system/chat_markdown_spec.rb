require "rails_helper"

RSpec.describe "Chat Markdown", type: :system do
  before { driven_by(:selenium_chrome_headless) }

  let(:user) { User.create!(email: "markdown@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  before { login_as(user, scope: :user) }

  it "formats saved assistant replies without changing user text or adding leading blank space" do
    question = chat.messages.create!(role: "user", content: "**free food**")
    reply = chat.messages.create!(role: "assistant", content: "\n\n## Food support\n\n**Rainbow Kitchen**\n\n- Free meals\n- [Directory](https://example.com/food)")

    visit chat_path(chat)

    within("#message_#{reply.id} [data-markdown-target='output']") do
      expect(page).to have_css("h2", text: "Food support")
      expect(page).to have_css("strong", text: "Rainbow Kitchen")
      expect(page).to have_css("ul li", count: 2)
      expect(page).to have_link("Directory", href: "https://example.com/food")
      expect(find("h2").style("margin-top")["margin-top"]).to eq("0px")
    end
    within("#message_#{question.id}_content") do
      expect(page).to have_text("**free food**")
      expect(page).not_to have_css("strong")
    end
    expect(reply.reload.content).to start_with("\n\n")
  end

  it "sanitizes model HTML and unsafe links while preserving code as text" do
    reply = chat.messages.create!(role: "assistant", content: <<~MARKDOWN)
      <script>window.markdownUnsafe = true</script>
      <img src="/missing-image" onerror="window.markdownUnsafe = true">
      <a href="javascript:alert(1)" onclick="window.markdownUnsafe = true" data-controller="dialog">Unsafe link</a>

      ```html
        <script>example()</script>
      ```
    MARKDOWN

    visit chat_path(chat)

    within("#message_#{reply.id} [data-markdown-target='output']") do
      expect(page).to have_text("Unsafe link")
      expect(page).not_to have_css("script, img, [onclick], [onerror], [data-controller]", visible: :all)
      expect(page).not_to have_css("a[href^='javascript:']", visible: :all)
      expect(find("pre code").evaluate_script("this.textContent")).to eq("  <script>example()</script>\n")
    end
    expect(page.evaluate_script("window.markdownUnsafe === undefined")).to be(true)
  end

  it "formats Markdown split across streamed chunks and keeps it formatted after reload" do
    reply = chat.messages.create!(role: "assistant", content: "")
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    output = "#message_#{reply.id} [data-markdown-target='output']"

    reply.broadcast_append_chunk("\n\n**Rainbow")
    expect(page).to have_css(output, text: "Rainbow")
    reply.broadcast_append_chunk(" Kitchen**\n\n- Free meals\n\n<img src=x onerror='window.markdownUnsafe = true'>")
    within(output) do
      expect(page).to have_css("strong", text: "Rainbow Kitchen")
      expect(page).to have_css("ul li", text: "Free meals")
      expect(page).not_to have_css("img", visible: :all)
    end
    expect(page.evaluate_script("window.markdownUnsafe === undefined")).to be(true)

    reply.update!(content: "\n\n**Rainbow Kitchen**\n\n- Free meals")
    page.refresh
    expect(page).to have_css("#{output} strong", text: "Rainbow Kitchen")
    expect(page).to have_css("#{output} ul li", text: "Free meals")
  end
end
