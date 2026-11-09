require "rails_helper"

RSpec.describe ChatResponse, "cancellation" do
  let(:user) { User.create!(email: "stop-model@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:response) { described_class.enqueue!(chat: chat, content: "Find free meals", model: chat.model_id, provider: chat.provider) }

  before { allow(ChatResponseJob).to receive(:perform_later).and_return(true) }

  it "cancels a queued reply without claiming or running it" do
    response.cancel!

    expect(response.reload).to be_cancelled
    expect(response.finished_at).to be_present
    expect(response.claim!).to be(false)
    expect(response.user_message.content).to eq("Find free meals")
  end

  it "keeps a running reply active until its worker acknowledges cancellation" do
    response.claim!
    response.cancel!

    expect(response.reload).to be_cancelling
    expect(response).to be_active
    expect { described_class.enqueue!(chat: chat, content: "Another question", model: chat.model_id, provider: chat.provider) }.to raise_error(ChatResponse::Busy)
    expect(response.start_writing!).to be(false)
    expect(response.complete!).to be(false)
    response.fail!
    expect(response.reload).to be_cancelling

    response.acknowledge_cancellation!
    expect(response.reload).to be_cancelled
    expect { described_class.enqueue!(chat: chat, content: "Another question", model: chat.model_id, provider: chat.provider) }.not_to raise_error
  end

  it "makes repeated stops and late stops idempotent" do
    response.claim!
    response.start_writing!
    response.complete!
    2.times { response.cancel! }
    expect(response.reload).to be_completed
  end

  it "reads cancellation without using a cached status" do
    response.claim!
    described_class.cache do
      expect(response.cancellation_requested?).to be(false)
      described_class.find(response.id).cancel!
      expect(response.cancellation_requested?).to be(true)
    end
  end
end
