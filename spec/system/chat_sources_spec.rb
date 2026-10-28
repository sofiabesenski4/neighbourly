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
  let(:document) do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.1))
    Document.create!(title: "Downtown Shelter", content: "Open 24 hours", source: source)
  end

  before do
    rag_context = instance_double(RagContext)
    allow(RagContext).to receive(:new).and_return(rag_context)
    allow(rag_context).to receive(:augment).and_return(
      RagContext::Result.new(prompt: "augmented prompt", documents: [document])
    )
    allow_any_instance_of(Chat).to receive(:ask).and_yield(double("chunk", content: "Try the downtown shelter."))

    chat.messages.create!(role: "user", content: "Where can I find shelter?")
    chat.messages.create!(role: "assistant", content: "")

    login_as(user, scope: :user)
  end

  it "shows a Report button on sources broadcast after the reply" do
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)

    ChatResponseJob.perform_now(chat.id, "Where can I find shelter?")

    assistant = chat.messages.where(role: "assistant").last
    within("#message_#{assistant.id}_rag_context") do
      find("summary", text: "Sources (1)").click

      expect(page).to have_content("Downtown Shelter")
      expect(page).to have_button("Report")
    end
  end
end
