require "rails_helper"

RSpec.describe Message, type: :model do
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "visibility@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  def create_tool_call_message
    Message.transaction do
      message = chat.messages.create!(role: "assistant", content: "Private tool request")
      attach_tool_call(message)
      message
    end
  end

  def attach_tool_call(message)
    message.ruby_llm_tool_calls.create!(tool_call_id: "call_#{message.id}", name: "search_resources", arguments: {private_query: "Raw search payload"})
  end

  it "selects user and assistant replies while preserving internal history for the model" do
    question = chat.messages.create!(role: "user", content: "Find meals")
    placeholder = chat.messages.create!(role: "assistant", content: "")
    system = chat.messages.create!(role: "system", content: "Private instructions")
    tool = chat.messages.create!(role: "tool", content: "Private tool result")
    tool_call = create_tool_call_message

    expect(chat.messages.visible_in_conversation).to contain_exactly(question, placeholder)
    expect(chat.messages).to include(system, tool, tool_call)
    expect(tool_call).not_to be_conversation_visible
    expect(placeholder).to be_conversation_visible
  end

  it "does not broadcast internal instructions, results, or tool requests" do
    expect {
      perform_enqueued_jobs do
        chat.messages.create!(role: "system", content: "Private instructions")
        chat.messages.create!(role: "tool", content: "Private tool result")
        create_tool_call_message
      end
    }.not_to have_broadcasted_to(chat.stream_name)
  end

  it "does not broadcast updates or deletions of hidden system and tool records" do
    records = %w[system tool].map { |role| chat.messages.create!(role: role, content: "Internal payload") }

    expect {
      perform_enqueued_jobs do
        records.each do |message|
          message.update!(content: "More internal payload")
          message.destroy!
        end
      end
    }.not_to have_broadcasted_to(chat.stream_name)
  end

  it "removes a visible placeholder when it becomes a tool request" do
    message = chat.messages.create!(role: "assistant", content: "")

    expect {
      perform_enqueued_jobs do
        Message.transaction do
          attach_tool_call(message)
          message.update!(content: "Private tool request")
        end
      end
    }.to have_broadcasted_to(chat.stream_name).with(
      a_string_including('action="remove"', "target=\"message_#{message.id}\"")
    )

    expect(message).not_to be_conversation_visible
  end

  it "guards direct chunk and reference broadcasts for internal records" do
    system = chat.messages.create!(role: "system", content: "Private instructions")
    tool = chat.messages.create!(role: "tool", content: "Private tool result")
    tool_call = create_tool_call_message

    expect {
      [system, tool, tool_call].each do |message|
        message.broadcast_append_chunk("Private chunk")
        message.broadcast_rag_context
      end
    }.not_to have_broadcasted_to(chat.stream_name)
  end

  it "continues streaming public assistant text" do
    message = chat.messages.create!(role: "assistant", content: "")

    expect {
      message.broadcast_append_chunk("A public answer")
    }.to have_broadcasted_to(chat.stream_name).with(
      a_string_including("target=\"message_#{message.id}_content\"", "A public answer")
    )
  end
end
