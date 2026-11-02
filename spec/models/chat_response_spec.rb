require "rails_helper"

RSpec.describe ChatResponse, type: :model do
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "response-model@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Local support") }

  def enqueue(content = "Where can I find meals?")
    described_class.enqueue!(chat: chat, content: content, model: chat.model_id, provider: chat.provider)
  end

  it "saves the original question before enqueueing the selected model" do
    response = nil
    expect {
      response = enqueue("Where can I find meals?\nNear downtown")
    }.to have_enqueued_job(ChatResponseJob).with(chat.id, "Where can I find meals?\nNear downtown", model: chat.model_id, provider: chat.provider.to_s, response_id: kind_of(Integer), attempt_token: kind_of(String))

    expect(response).to be_queued
    expect(response.user_message).to have_attributes(role: "user", content: "Where can I find meals?\nNear downtown", chat_id: chat.id)
    expect(chat.messages.where(role: "user").count).to eq(1)
    expect(response.heartbeat_at).to be_present
  end

  it "rejects another active request without saving a duplicate question" do
    enqueue

    expect {
      expect { enqueue("Another question") }.to raise_error(described_class::Busy)
    }.not_to change { chat.messages.where(role: "user").count }
    expect(described_class.active.where(chat: chat).count).to eq(1)
  end

  it "allows the next question after the response completes" do
    first = enqueue
    expect(first.complete!).to be(true)

    second = enqueue("What is open today?")

    expect(second).to be_queued
    expect(chat.messages.where(role: "user").count).to eq(2)
  end

  it "claims work once and records when generation began" do
    response = enqueue

    expect(response.claim!).to be(true)
    expect(response.reload).to be_searching
    expect(response.started_at).to be_present
    expect(response.claim!).to be(false)
  end

  it "does not overwrite a terminal status with a late completion or failure" do
    response = enqueue
    response.fail!

    expect(response.complete!).to be(false)
    expect(response.reload).to be_failed
    response.update!(status: "completed")
    response.fail!
    expect(response.reload).to be_completed
  end

  it "rolls back the question if response validation fails" do
    chat
    expect {
      expect { enqueue(" \n ") }.to raise_error(ActiveRecord::RecordInvalid)
    }.not_to change(Message, :count)
    expect(described_class.where(chat: chat)).to be_empty
  end

  it "requires both linked messages to belong to the same conversation and role" do
    another_chat = user.chats.create!
    question = another_chat.messages.create!(role: "user", content: "A private question")
    response = described_class.new(chat: chat, user_message: question, model_id: chat.model_id, provider: chat.provider)

    expect(response).not_to be_valid
    expect(response.errors[:user_message]).to include("must be a nonempty question in this conversation")
  end

  it "throttles heartbeat writes while preserving the current status" do
    response = enqueue
    response.claim!
    initial = response.reload.heartbeat_at
    response.heartbeat!
    expect(response.reload.heartbeat_at).to eq(initial)

    travel 11.seconds do
      response.heartbeat!
      expect(response.reload.heartbeat_at).to be > initial
      expect(response).to be_searching
    end
  end

  it "does not broadcast an older response over a newer response's status" do
    first = enqueue
    first.complete!
    enqueue("A newer question")

    expect { first.broadcast_status }.not_to have_broadcasted_to("chat_#{chat.id}")
  end

  it "reloads the latest state before broadcasting a delayed status" do
    response = enqueue
    described_class.find(response.id).update!(status: "writing")

    expect { response.broadcast_status }.to have_broadcasted_to("chat_#{chat.id}").with(
      a_string_including("Writing a response")
    )
  end

  it "ignores broadcasts after the conversation has been deleted" do
    response = enqueue
    chat.destroy!

    expect { response.broadcast_status }.not_to raise_error
  end
end
