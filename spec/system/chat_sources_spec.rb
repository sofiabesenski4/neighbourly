require "rails_helper"

# Sources arrive over a Turbo Stream once the assistant finishes replying,
# so this needs a real browser subscribed to the chat's stream.
RSpec.describe "Chat sources", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
  end

  let(:user) { User.create!(email: "sourcesuser@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:source) { Source.create!(name: "Shelter Directory", url: "https://example.com/shelters", source_type: "html") }
  let(:question) { chat.messages.create!(role: "user", content: "Where can I find shelter?") }
  let(:reply) { chat.messages.create!(role: "assistant", content: "Try the downtown shelter.") }
  let(:document) do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.1))
    Document.create!(title: "Downtown Shelter", content: "Open 24 hours. " * 30 + "Full reference ends here.", source: source)
  end

  before do
    rag_context = instance_double(RagContext)
    allow(RagContext).to receive(:new).and_return(rag_context)
    allow(rag_context).to receive(:augment).and_return(
      RagContext::Result.new(instructions: "reference instructions", documents: [document])
    )
    allow_any_instance_of(Chat).to receive(:ask).and_yield(double("chunk", content: "Try the downtown shelter."))

    question
    reply

    login_as(user, scope: :user)
  end

  it "shows references only beneath the assistant after a streamed reply and after reload" do
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)

    ChatResponseJob.perform_now(chat.id, "Where can I find shelter?")

    expect(page).to have_css("summary", text: "References · 1", count: 1)
    within("#message_#{question.id}") do
      expect(page).not_to have_css("summary", text: "References")
    end
    within("#message_#{reply.id}_rag_context") do
      find("summary", text: "References · 1").click

      expect(page).to have_content("Downtown Shelter")
      expect(page).to have_link("Shelter Directory", href: source.url)
      expect(page).to have_button("Report")
    end

    page.refresh
    expect(page).to have_css("summary", text: "References · 1", count: 1)
    within("#message_#{question.id}") do
      expect(page).not_to have_css("summary", text: "References")
    end
    expect(question.rag_documents).to include(document)
  end

  it "shows the title and source while keeping document details behind an expansion" do
    reply.rag_documents << document
    visit chat_path(chat)

    find("summary", text: "References · 1").click
    expect(page).to have_content("Downtown Shelter")
    expect(page).to have_link("Shelter Directory", href: source.url)
    expect(page).not_to have_content("Open 24 hours.")
    expect(page).not_to have_content("Full reference ends here.")

    find("summary", text: "View full text").click
    expect(page).to have_content("Open 24 hours.")
    expect(page).to have_content("Full reference ends here.")
    find("summary", text: "View full text").click
    expect(page).not_to have_content("Full reference ends here.")
  end

  it "keeps document reporting available from the reference panel" do
    reply.rag_documents << document
    visit chat_path(chat)

    find("summary", text: "References · 1").click
    click_button "Report", exact: true
    within("dialog[open]") do
      expect(page).to have_content("Downtown Shelter")
      choose "Out of date"
      fill_in "Additional details (optional)", with: "The hours have changed."
      click_button "Submit Report"
    end

    expect(page).to have_content("Thank you. Your report has been submitted.")
    expect(Report.last).to have_attributes(document_id: document.id, user_id: user.id, reason: "out of date", details: "The hours have changed.")
  end

  it "shows references without a public URL without inventing a link" do
    source.update!(source_type: "form", url: nil)
    document.update!(title: nil)
    reply.rag_documents << document
    visit chat_path(chat)

    find("summary", text: "References · 1").click
    within("#message_#{reply.id}_rag_context") do
      expect(page).to have_content("Untitled reference")
      expect(page).to have_content("Shelter Directory · No public link available")
      expect(page).not_to have_link("Shelter Directory")
      expect(page).to have_button("Report")
    end
  end

  it "does not show a references control when no documents are associated" do
    visit chat_path(chat)

    expect(page).to have_content("Try the downtown shelter.")
    expect(page).not_to have_css("summary", text: "References")
  end
end
