require "rails_helper"

RSpec.describe "Chat reference citations", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.1))
  end

  let(:user) { User.create!(email: "citations@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Meal references") }
  let(:source) { Source.create!(name: "Community Directory", url: "https://example.com/resources", source_type: "html") }
  let(:document) { source.documents.create!(title: "Rainbow Kitchen", content: "Weekday meal service.") }
  let(:other_document) { source.documents.create!(title: "Other services", content: "Additional local services.") }

  def output_for(reply)
    "#message_#{reply.id} [data-citations-target='content']"
  end

  def reference_for(reply, document)
    "#message_#{reply.id}_reference_#{document.id}"
  end

  it "links known citations to reference cards and distinguishes them from other retrieved documents" do
    reply = chat.messages.create!(role: "assistant", content: "Try Rainbow Kitchen [ref:#{document.id}]. Unverified [ref:999999999].")
    reply.rag_documents = [document, other_document]
    visit chat_path(chat)

    within(output_for(reply)) do
      expect(page).to have_link("[1]", href: reference_for(reply, document))
      expect(page).to have_text("[ref:999999999]")
      expect(page).not_to have_css("a[data-citation-reference='999999999']")
      click_link "[1]"
    end

    expect(page).to have_css("#message_#{reply.id}_rag_context > details[open]")
    expect(page).to have_css("#{reference_for(reply, document)} [data-citation-status]", text: "Cited")
    expect(page).not_to have_css("#{reference_for(reply, other_document)} [data-citation-status]", text: "Cited")
    expect(page.evaluate_script("document.activeElement.id")).to eq(reference_for(reply, document).delete_prefix("#"))
    expect(page).to have_link("Community Directory", href: source.url, count: 2)
  end

  it "resolves citations when reference metadata arrives later and preserves badges on panel replacement" do
    reply = chat.messages.create!(role: "assistant", content: "Try Rainbow Kitchen [ref:#{document.id}].")
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    expect(page).to have_css(output_for(reply), text: "[ref:#{document.id}]")
    expect(page).not_to have_css("#{output_for(reply)} a[data-citation-reference]")

    reply.rag_documents << document
    reply.broadcast_rag_context
    expect(page).to have_css("#{output_for(reply)} a[data-citation-reference='#{document.id}']")

    page.execute_script("window.previousCitationPanel = document.getElementById('message_#{reply.id}_rag_context')")
    reply.broadcast_rag_context
    expect(page).to have_css("#message_#{reply.id}_rag_context", visible: :all) do |panel|
      panel.evaluate_script("this !== window.previousCitationPanel")
    end
    expect(page).to have_css("#{reference_for(reply, document)} [data-citation-status]:not([hidden])", visible: :all)
    within(output_for(reply)) { click_link "[1]" }
    expect(page).to have_css("#{reference_for(reply, document)} [data-citation-status]", text: "Cited")
  end

  it "handles markers split across streamed chunks and later Markdown renders without duplicating citations" do
    reply = chat.messages.create!(role: "assistant", content: "")
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)

    reply.broadcast_append_chunk("Try Rainbow Kitchen [ref:")
    expect(page).to have_css(output_for(reply), text: "[ref:")
    reply.broadcast_append_chunk("#{document.id}].")
    expect(page).to have_css(output_for(reply), text: "[ref:#{document.id}]")
    reply.rag_documents << document
    reply.broadcast_rag_context
    expect(page).to have_css("#{output_for(reply)} a[data-citation-reference]", count: 1)

    reply.broadcast_append_chunk(" It serves meals [ref:#{document.id}].")
    expect(page).to have_css("#{output_for(reply)} a[data-citation-reference]", count: 2)
    within(output_for(reply)) { first("a[data-citation-reference]").click }
    expect(page).to have_css("#{reference_for(reply, document)} [data-citation-status]", count: 1)
  end

  it "does not treat code, arbitrary Markdown links, or model-injected attributes as verified citations" do
    reply = chat.messages.create!(role: "assistant", content: <<~MARKDOWN)
      Inline code: `[ref:#{document.id}]`

      ```text
      [ref:#{document.id}]
      ```

      [ref:#{document.id}](https://example.com/unverified)

      <a data-citation-reference="#{document.id}" href="https://example.com/fake">Fake citation</a>
    MARKDOWN
    reply.rag_documents << document
    visit chat_path(chat)

    within(output_for(reply)) do
      expect(page).to have_css("code", text: "[ref:#{document.id}]", count: 2)
      expect(page).to have_link("ref:#{document.id}", href: "https://example.com/unverified")
      expect(page).to have_link("Fake citation", href: "https://example.com/fake")
      expect(page).not_to have_css("a[data-citation-reference]")
    end
    find("summary", text: "References · 1").click
    expect(page).not_to have_css("#{reference_for(reply, document)} [data-citation-status]", text: "Cited")
  end

  it "never resolves a marker using another message's references" do
    first_reply = chat.messages.create!(role: "assistant", content: "First answer [ref:#{document.id}].")
    first_reply.rag_documents << document
    second_reply = chat.messages.create!(role: "assistant", content: "Another answer [ref:#{document.id}].")
    second_reply.rag_documents << other_document
    visit chat_path(chat)

    expect(page).to have_css("#{output_for(first_reply)} a[data-citation-reference='#{document.id}']")
    expect(page).to have_css(output_for(second_reply), text: "[ref:#{document.id}]")
    expect(page).not_to have_css("#{output_for(second_reply)} a[data-citation-reference]")
  end

  it "uses plain text for untrusted reference titles" do
    document.update!(title: '<img src=x onerror="window.citationUnsafe = true">')
    reply = chat.messages.create!(role: "assistant", content: "A referenced answer [ref:#{document.id}].")
    reply.rag_documents << document
    visit chat_path(chat)

    expect(page).to have_css("#{output_for(reply)} a[data-citation-reference]")
    within(output_for(reply)) { click_link "[1]" }
    expect(page).not_to have_css("#message_#{reply.id} img", visible: :all)
    expect(page.evaluate_script("window.citationUnsafe === undefined")).to be(true)
  end

  it "keeps reports on a later reference associated with the selected document" do
    reply = chat.messages.create!(role: "assistant", content: "A referenced answer [ref:#{document.id}].")
    reply.rag_documents = [document, other_document]
    visit chat_path(chat)

    find("summary", text: "References · 2").click
    within(reference_for(reply, other_document)) { click_button "Report", exact: true }
    within("dialog[open]") do
      choose "Out of date"
      fill_in "Additional details (optional)", with: "The details have changed."
      click_button "Submit Report"
    end

    expect(page).to have_content("Thank you. Your report has been submitted.")
    expect(Report.last).to have_attributes(document_id: other_document.id, details: "The details have changed.")
  end
end
