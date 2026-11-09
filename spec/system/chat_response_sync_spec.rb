require "rails_helper"

RSpec.describe "Chat response reconciliation", type: :system do
  let(:user) { User.create!(email: "response-sync@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Community resources") }

  before do
    driven_by(:selenium_chrome_headless)
    login_as(user, scope: :user)
    allow(ChatResponseJob).to receive(:perform_later)
  end

  def resume_page
    page.execute_script("window.dispatchEvent(new Event('focus'))")
  end

  it "shows the first reply when its initial message broadcast was missed" do
    visit new_chat_path
    fill_in "Prompt", with: "Find meals in Victoria"
    click_button "Start new chat"

    expect(page).to have_text("Getting ready")
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    page.document.synchronize do
      synced = page.evaluate_script(<<~JS)
        (() => {
          const workspace = document.querySelector('[data-controller~="response-sync"]');
          const sync = window.Stimulus.getControllerForElementAndIdentifier(workspace, 'response-sync');
          return Boolean(sync && sync.boundary !== '0' && !sync.request);
        })()
      JS
      raise Capybara::ElementNotFound unless synced
    end

    record = user.chats.last.latest_response
    allow(ActionCable.server).to receive(:broadcast).and_wrap_original do |broadcast, stream, html, **options|
      unless html.include?('action="append" target="messages"') && html.include?('aria-label="Assistant message"')
        broadcast.call(stream, html, **options)
      end
    end
    answer = record.chat.messages.create!(role: "assistant", content: "")
    answer.update!(content: "Try Rainbow Kitchen.")
    record.update!(assistant_message: answer, status: "completed")

    expect(page).to have_css("[data-responding='false']", visible: :all)
    expect(page).to have_css("#message_#{answer.id}", text: "Try Rainbow Kitchen.", count: 1)
  end

  it "echoes a saved question over HTTP and recovers a missed final answer without Cable" do
    allow(ActionCable.server).to receive(:broadcast)
    visit chat_path(chat)
    fill_in "Message", with: "Find meals in Victoria"
    click_button "Send message"

    expect(page).to have_field("Message", with: "")
    record = chat.chat_responses.last
    expect(page).to have_css("#message_#{record.user_message_id}", text: "Find meals in Victoria", count: 1)
    expect(page).to have_text("Getting ready")
    fill_in "Message", with: "My next question"
    expect(page).to have_button("Send message", disabled: true)

    answer = chat.messages.create!(role: "assistant", content: "Try Rainbow Kitchen.")
    record.update!(assistant_message: answer, status: "completed")
    # Cable can report connected even when the server cannot broadcast.
    expect(page).to have_css("#message_#{answer.id}", text: "Try Rainbow Kitchen.", wait: 20)
    expect(page).to have_button("Send message", disabled: false)
    expect(page).to have_field("Message", with: "My next question")
    expect(page).to have_css("#message_#{record.user_message_id}", count: 1)
  end

  it "ignores an older queued HTTP status after a completed Cable update" do
    record = ChatResponse.enqueue!(chat: chat, content: "Find food", model: chat.model_id, provider: chat.provider)
    queued = ApplicationController.render(partial: "chats/response_status", locals: {chat: chat, response: record})
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    fill_in "Message", with: "Next question"
    record.update!(status: "completed")
    expect(page).to have_button("Send message", disabled: false)

    page.execute_script(<<~JS, "chat_#{chat.id}_response_status", queued)
      const stream = document.createElement('turbo-stream');
      stream.setAttribute('action', 'replace');
      stream.setAttribute('target', arguments[0]);
      const template = document.createElement('template');
      template.innerHTML = arguments[1];
      stream.append(template);
      document.body.append(stream);
    JS

    expect(page).not_to have_css("turbo-stream[target='chat_#{chat.id}_response_status']", visible: :all)
    expect(page).to have_css("[data-responding='false']", visible: :all)
    expect(page).to have_button("Send message", disabled: false)
    expect(page).not_to have_text("Getting ready")
  end

  it "keeps streamed text while a writing response is reconciled" do
    record = ChatResponse.enqueue!(chat: chat, content: "Find food", model: chat.model_id, provider: chat.provider)
    answer = chat.messages.create!(role: "assistant", content: "")
    record.update!(assistant_message: answer, status: "writing")
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    answer.broadcast_append_chunk("A response being streamed")
    expect(page).to have_text("A response being streamed")

    resume_page

    expect(page).to have_text("A response being streamed")
    expect(page).to have_text("Writing a response")
  end

  it "repairs missed reference enrichment once and preserves unchanged answer DOM" do
    allow(ActionCable.server).to receive(:broadcast)
    record = ChatResponse.enqueue!(chat: chat, content: "Find food", model: chat.model_id, provider: chat.provider)
    answer = chat.messages.create!(role: "assistant", content: "Try Rainbow Kitchen.")
    record.update!(assistant_message: answer, status: "completed")
    visit chat_path(chat)
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.1))
    source = Source.create!(name: "Local directory", source_type: "html", url: "https://example.com/food")
    document = Document.create!(title: "Rainbow Kitchen", content: "Free meals.", source: source)
    answer.rag_documents << document

    resume_page
    expect(page).to have_css("summary", text: "References · 1")
    find("summary", text: "References · 1").click
    page.execute_script("document.getElementById(arguments[0]).dataset.preserved = 'yes'", "message_#{answer.id}")
    resume_page

    expect(page).to have_css("#message_#{answer.id}[data-preserved='yes']")
    expect(page).to have_text("Rainbow Kitchen")
  end

  it "removes a retried partial answer without Cable while preserving the draft" do
    allow(ActionCable.server).to receive(:broadcast)
    record = ChatResponse.enqueue!(chat: chat, content: "Find food", model: chat.model_id, provider: chat.provider)
    answer = chat.messages.create!(role: "assistant", content: "An interrupted answer")
    record.update!(assistant_message: answer, status: "failed")
    visit chat_path(chat)
    expect(page).to have_text("An interrupted answer")
    fill_in "Message", with: "My next question"

    click_button "Retry reply"

    expect(page).to have_text("Getting ready")
    expect(page).not_to have_css("#message_#{answer.id}")
    expect(page).to have_field("Message", with: "My next question")
    expect(page).to have_css("#message_#{record.user_message_id}", count: 1)
  end

  it "inserts a missed question before its existing answer without replacing the answer" do
    allow(ActionCable.server).to receive(:broadcast)
    record = ChatResponse.enqueue!(chat: chat, content: "Find food", model: chat.model_id, provider: chat.provider)
    answer = chat.messages.create!(role: "assistant", content: "Try Rainbow Kitchen.")
    record.update!(assistant_message: answer, status: "completed")
    visit chat_path(chat)
    page.execute_script(<<~JS, "message_#{record.user_message_id}", "message_#{answer.id}")
      document.getElementById(arguments[0]).remove();
      document.getElementById(arguments[1]).dataset.preserved = 'yes';
    JS

    resume_page

    expect(page).to have_css("#message_#{record.user_message_id}")
    expect(page).to have_css("#message_#{answer.id}[data-preserved='yes']")
    ids = page.all("#messages > [id]").map { |element| element[:id] }
    expect(ids).to eq(["message_#{record.user_message_id}", "message_#{answer.id}"])
  end

  it "repairs two missed completed pairs even when the latest Cable status is already known" do
    allow(ActionCable.server).to receive(:broadcast)
    records = 3.times.map do |index|
      record = ChatResponse.enqueue!(chat: chat, content: "Question #{index}", model: chat.model_id, provider: chat.provider)
      answer = chat.messages.create!(role: "assistant", content: "Answer #{index}")
      record.update!(assistant_message: answer, status: "completed")
      record
    end
    visit chat_path(chat)
    missing_ids = records.drop(1).flat_map { |record| [record.user_message_id, record.assistant_message_id] }
    page.execute_script("arguments[0].forEach(id => document.getElementById(`message_${id}`).remove())", missing_ids)
    expect(page).to have_css("[data-response-id='#{records.last.id}']", visible: :all)

    resume_page

    missing_ids.each { |id| expect(page).to have_css("#message_#{id}") }
    expected_ids = records.flat_map { |record| ["message_#{record.user_message_id}", "message_#{record.assistant_message_id}"] }
    expect(page.all("#messages > [id]").map { |element| element[:id] }).to eq(expected_ids)
  end
end
