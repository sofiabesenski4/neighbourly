require "rails_helper"

RSpec.describe "Chat response attempt ownership", type: :model do
  let(:user) { User.create!(email: "attempt@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:record) { ChatResponse.enqueue!(chat: chat, content: "Find meals", model: chat.model_id, provider: chat.provider) }

  it "does not let an old queued job claim a retried response" do
    original_token = record.attempt_token
    record.fail!
    record.retry!
    expect(record.reload.attempt_token).not_to eq(original_token)
    expect(RagContext).not_to receive(:new)

    ChatResponseRunner.new(record.id, attempt_token: original_token).call

    expect(record.reload).to be_queued
  end

  it "rejects an expired worker's transitions after another attempt starts" do
    old_worker = ChatResponse.find(record.id)
    old_worker.expected_attempt_token = old_worker.attempt_token
    old_worker.claim!
    record.fail!
    record.retry!
    record.claim!
    heartbeat = record.reload.heartbeat_at

    expect(old_worker.complete!).to be(false)
    old_worker.fail!
    old_worker.heartbeat!
    expect(old_worker.start_writing!).to be(false)
    expect { old_worker.while_running {} }.to raise_error(RubyLLM::CancelledError)
    expect(old_worker.cancellation_requested?).to be(true)
    expect(record.reload).to have_attributes(status: "searching", heartbeat_at: heartbeat)
  end

  it "guards the SDK's final message save after a response has expired" do
    worker = ChatResponse.find(record.id)
    worker.expected_attempt_token = worker.attempt_token
    worker.claim!
    worker.start_writing!
    assistant = chat.messages.create!(role: "assistant", content: "Saved partial")
    assistant.chat_response_run = worker
    assistant.update!(content: "Current partial")
    record.fail!
    record.retry!
    assistant.content = "Late result from an expired attempt"

    expect { assistant.save! }.to raise_error(RubyLLM::CancelledError)
    expect(assistant.reload.content).to eq("Current partial")
    expect(record.reload).to be_queued
  end

  it "allows cancellation acknowledgement to preserve a partial but blocks later writes" do
    worker = ChatResponse.find(record.id)
    worker.expected_attempt_token = worker.attempt_token
    worker.claim!
    worker.start_writing!
    assistant = chat.messages.create!(role: "assistant", content: "")
    assistant.chat_response_run = worker
    record.cancel!

    assistant.update!(content: "Text received before Stop")
    worker.acknowledge_cancellation!
    assistant.content = "Unexpected later text"

    expect { assistant.save! }.to raise_error(RubyLLM::CancelledError)
    expect(assistant.reload.content).to eq("Text received before Stop")
  end
end
