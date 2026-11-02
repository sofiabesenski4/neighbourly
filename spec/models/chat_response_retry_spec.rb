require "rails_helper"

RSpec.describe "Retrying a chat response", type: :model do
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "retry-model@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:response_record) { ChatResponse.enqueue!(chat: chat, content: "Find free meals", model: chat.model_id, provider: chat.provider) }

  before do
    response_record.update!(status: "failed", started_at: 2.minutes.ago,
      finished_at: 1.minute.ago, heartbeat_at: 1.minute.ago, error_message: ChatResponse::FAILED_MESSAGE)
    clear_enqueued_jobs
  end

  it "reuses the saved question and original model without creating another message" do
    original_model = response_record.model_id
    original_provider = response_record.provider
    original_question = response_record.user_message_id

    expect {
      expect { expect(response_record.retry!).to eq(:queued) }
        .not_to change(Message, :count)
    }.to have_enqueued_job(ChatResponseJob).with(chat.id, "Find free meals", model: original_model, provider: original_provider, response_id: response_record.id, attempt_token: kind_of(String))

    expect(response_record.reload).to have_attributes(status: "queued", user_message_id: original_question,
      model_id: original_model, provider: original_provider, started_at: nil, finished_at: nil, error_message: nil)
    expect(response_record.heartbeat_at).to be > 1.minute.ago
    expect(chat.chat_responses.count).to eq(1)
  end

  it "removes the old partial answer before enqueueing replacement work" do
    partial = chat.messages.create!(role: "assistant", content: "An incomplete answer")
    response_record.update!(assistant_message: partial)

    expect(ChatResponseJob).to receive(:perform_later) do
      expect(Message.exists?(partial.id)).to be(false)
      expect(response_record.reload.assistant_message_id).to be_nil
    end

    expect(response_record.retry!).to eq(:queued)
  end

  it "does not retry a reply twice" do
    expect {
      expect(response_record.retry!).to eq(:queued)
      expect(response_record.retry!).to eq(:conflict)
    }.to have_enqueued_job(ChatResponseJob).exactly(:once)
  end

  it "rejects an older failed reply" do
    newer = ChatResponse.enqueue!(chat: chat, content: "A newer question", model: chat.model_id, provider: chat.provider)
    newer.complete!
    clear_enqueued_jobs

    expect { expect(response_record.retry!).to eq(:conflict) }.not_to have_enqueued_job(ChatResponseJob)
    expect(response_record.reload).to be_failed
  end

  it "rejects retrying when another response is active" do
    response_record.update!(status: "queued")
    latest_question = chat.messages.create!(role: "user", content: "A later failed question")
    latest = chat.chat_responses.create!(user_message: latest_question, model_id: chat.model_id,
      provider: chat.provider, status: "failed")
    clear_enqueued_jobs

    expect { expect(latest.retry!).to eq(:conflict) }.not_to have_enqueued_job(ChatResponseJob)
    expect(latest.reload).to be_failed
  end

  it "preserves the failed reply if its original model is unavailable" do
    partial = chat.messages.create!(role: "assistant", content: "An incomplete answer")
    response_record.update!(assistant_message: partial)
    availability = instance_double(ChatModelAvailability)
    allow(ChatModelAvailability).to receive(:new).and_return(availability)
    expect(availability).to receive(:find).with(response_record.model_id, provider: response_record.provider).and_return(nil)

    expect { expect(response_record.retry!).to eq(:unavailable) }.not_to have_enqueued_job(ChatResponseJob)
    expect(response_record.reload).to have_attributes(status: "failed", assistant_message_id: partial.id,
      error_message: ChatResponse::FAILED_MESSAGE)
    expect(Message.exists?(partial.id)).to be(true)
  end

  it "rolls back partial removal and queues no job if the enclosing transaction is rolled back" do
    partial = chat.messages.create!(role: "assistant", content: "An incomplete answer")
    response_record.update!(assistant_message: partial)

    expect {
      ChatResponse.transaction do
        expect(response_record.retry!).to eq(:queued)
        raise ActiveRecord::Rollback
      end
    }.not_to have_enqueued_job(ChatResponseJob)

    expect(response_record.reload).to have_attributes(status: "failed", assistant_message_id: partial.id)
    expect(Message.exists?(partial.id)).to be(true)
  end
end
