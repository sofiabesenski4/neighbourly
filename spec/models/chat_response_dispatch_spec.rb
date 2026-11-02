require "rails_helper"

RSpec.describe "Dispatching a saved chat response", type: :model do
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "dispatch@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  before { allow(Rails.error).to receive(:report) }

  def enqueue
    ChatResponse.enqueue!(chat: chat, content: "Find meals", model: chat.model_id, provider: chat.provider)
  end

  it "enqueues work even when its live status cannot be broadcast" do
    allow_any_instance_of(ChatResponse).to receive(:broadcast_replace_to).and_raise(IOError, "Cable unavailable")

    record = nil
    expect { record = enqueue }.to have_enqueued_job(ChatResponseJob)

    expect(record.reload).to be_queued
    expect(Rails.error).to have_received(:report)
  end

  it "shows a recoverable failure when the queue rejects a job" do
    allow(ChatResponseJob).to receive(:perform_later).and_return(false)

    record = enqueue

    expect(record.reload).to be_failed
    expect(record.user_message.content).to eq("Find meals")
    expect(chat).not_to be_response_in_progress
  end

  it "keeps the question and frees the conversation when the queue raises" do
    allow(ChatResponseJob).to receive(:perform_later).and_raise(IOError, "Queue unavailable")

    record = enqueue

    expect(record.reload).to be_failed
    expect(record.error_message).not_to include("Queue unavailable")
    expect(record.user_message.content).to eq("Find meals")
    expect(Rails.error).to have_received(:report)
  end
end
