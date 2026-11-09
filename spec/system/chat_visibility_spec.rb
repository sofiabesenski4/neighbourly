require "rails_helper"

RSpec.describe "Conversation message visibility", type: :system do
  include ActiveJob::TestHelper

  before do
    driven_by(:selenium_chrome_headless)
    login_as(user, scope: :user)
  end

  let(:user) { User.create!(email: "visible-conversation@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Meal options") }

  def add_internal_messages
    chat.messages.create!(role: "system", content: "Private system instructions")
    chat.messages.create!(role: "tool", content: "Private tool result")
    Message.transaction do
      message = chat.messages.create!(role: "assistant", content: "Private tool request")
      message.ruby_llm_tool_calls.create!(tool_call_id: "call_#{message.id}", name: "internal_lookup", arguments: {secret: "Private search argument"})
    end
  end

  it "hides internal records on load while showing the question and answer" do
    add_internal_messages
    chat.messages.create!(role: "user", content: "Where can I find meals?")
    chat.messages.create!(role: "assistant", content: "Try the community kitchen.")

    visit chat_path(chat)

    expect(page).to have_text("Where can I find meals?")
    expect(page).to have_text("Try the community kitchen.")
    expect(page).not_to have_text("Private", exact: false)
    expect(page).not_to have_text("Tool Call")
  end

  it "keeps internal broadcasts out of an open conversation while streaming an answer" do
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)

    perform_enqueued_jobs { add_internal_messages }
    placeholder = nil
    perform_enqueued_jobs do
      placeholder = chat.messages.create!(role: "assistant", content: "")
    end
    expect(page).to have_css("#message_#{placeholder.id}", visible: :all)
    placeholder.broadcast_append_chunk("A public streamed answer")

    expect(page).to have_text("A public streamed answer")
    expect(page).not_to have_text("Private", exact: false)
    expect(page).not_to have_text("Tool Call")
  end

  it "removes a placeholder when the completed assistant message contains tool calls" do
    placeholder = chat.messages.create!(role: "assistant", content: "")
    visit chat_path(chat)
    expect(page).to have_css("turbo-cable-stream-source[connected]", visible: :all)
    expect(page).to have_css("#message_#{placeholder.id}", visible: :all)

    perform_enqueued_jobs do
      Message.transaction do
        placeholder.ruby_llm_tool_calls.create!(tool_call_id: "call_#{placeholder.id}", name: "internal_lookup", arguments: {secret: "Private search argument"})
        placeholder.update!(content: "Private tool request")
      end
    end

    expect(page).not_to have_css("#message_#{placeholder.id}", visible: :all)
    expect(page).not_to have_text("Private", exact: false)
    expect(chat.messages).to include(placeholder)
  end
end
