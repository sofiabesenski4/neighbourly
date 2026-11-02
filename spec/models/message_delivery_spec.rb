require "rails_helper"

RSpec.describe "Message delivery resilience", type: :model do
  include ActiveJob::TestHelper

  it "persists and enqueues the reply even when Cable transmission fails" do
    user = User.create!(email: "delivery@example.com", password: "password123")
    chat = user.chats.create!(title: "Meals")
    allow(ActionCable.server).to receive(:broadcast).and_raise(IOError, "Cable unavailable")
    allow(Rails.error).to receive(:report)

    response = ChatResponse.enqueue!(chat: chat, content: "Find food", model: chat.model_id, provider: chat.provider)

    expect(response).to be_persisted
    expect(response.user_message.reload.content).to eq("Find food")
    expect(ChatResponseJob).to have_been_enqueued.with(chat.id, "Find food", model: chat.model_id,
      provider: chat.provider, response_id: response.id, attempt_token: response.attempt_token)
    expect(Rails.error).to have_received(:report).with(an_instance_of(IOError), any_args).at_least(:once)
  end
end
