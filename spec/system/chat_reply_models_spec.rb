require "rails_helper"

RSpec.describe "Reply model attribution", type: :system do
  include ActiveJob::TestHelper

  before do
    driven_by(:selenium_chrome_headless)
    page.current_window.resize_to(1280, 900)
    login_as(user, scope: :user)
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([first_model, second_model]))
  end

  let(:user) { User.create!(email: "reply-model-ui@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:first_model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }
  let(:second_model) { RubyLLM::Model.new(id: "claude-sonnet-4-5", name: "Claude Sonnet", provider: "anthropic") }

  def record_usage(reply, model)
    reply.ruby_llm_usages.create!(chat: chat, provider: model.provider, model: model.id, status: "succeeded", operation: "chat")
  end

  it "keeps historical attribution after switching the conversation's model and after reload" do
    first_reply = chat.messages.create!(role: "assistant", content: "The original reply")
    record_usage(first_reply, first_model)
    chat.with_model(second_model.id, provider: second_model.provider)
    second_reply = chat.messages.create!(role: "assistant", content: "The newer reply")
    record_usage(second_reply, second_model)
    legacy_reply = chat.messages.create!(role: "assistant", content: "An older reply without usage metadata")

    visit chat_path(chat)

    within("#message_#{first_reply.id}") { expect(page).to have_text("Answered with Anthropic - Claude Haiku") }
    within("#message_#{second_reply.id}") { expect(page).to have_text("Answered with Anthropic - Claude Sonnet") }
    within("#message_#{legacy_reply.id}") { expect(page).not_to have_css("[data-reply-model]") }

    page.refresh
    within("#message_#{first_reply.id}") { expect(page).to have_text("Answered with Anthropic - Claude Haiku") }
  end

  it "shows attribution when a streamed reply is completed" do
    reply = chat.messages.create!(role: "assistant", content: "")
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    within("#message_#{reply.id}") { expect(page).not_to have_css("[data-reply-model]") }

    record_usage(reply, first_model)
    perform_enqueued_jobs do
      reply.update!(content: "The completed answer")
    end

    within("#message_#{reply.id}") do
      expect(page).to have_text("The completed answer")
      expect(page).to have_text("Answered with Anthropic - Claude Haiku")
    end
  end
end
