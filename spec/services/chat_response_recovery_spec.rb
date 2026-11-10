require "rails_helper"

RSpec.describe ChatResponseRecovery do
  let(:user) { User.create!(email: "recovery@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:record) { ChatResponse.enqueue!(chat: chat, content: "Find food", model: chat.model_id, provider: chat.provider) }

  it "releases a queued request lost during a restart without losing its question" do
    record.update!(heartbeat_at: 3.minutes.ago)

    described_class.call(chat)

    expect(record.reload).to be_failed
    expect(record.error_message).to include("didn't start in time", "saved")
    expect(record.user_message.content).to eq("Find food")
    expect(chat).not_to be_response_in_progress
  end

  it "does not expire a healthy slow provider before all configured retries can finish" do
    record.update!(status: "writing", heartbeat_at: 6.minutes.ago)
    allow(RubyLLM.config).to receive(:request_timeout).and_return(300)
    allow(RubyLLM.config).to receive(:max_retries).and_return(3)

    described_class.call(chat)
    expect(record.reload).to be_writing

    record.update!(heartbeat_at: 22.minutes.ago)
    described_class.call(chat)
    expect(record.reload).to be_failed
  end

  it "finishes a cancellation whose worker has disappeared" do
    record.update!(status: "cancelling", heartbeat_at: 1.day.ago)

    described_class.call(chat)

    expect(record.reload).to be_cancelled
    expect(record.error_message).to be_nil
    expect(chat).not_to be_response_in_progress
  end

  it "does not alter fresh work or terminal responses" do
    record
    described_class.call(chat)
    expect(record.reload).to be_queued
    record.update!(status: "completed", heartbeat_at: 1.day.ago)
    described_class.call(chat)
    expect(record.reload).to be_completed
  end
end
