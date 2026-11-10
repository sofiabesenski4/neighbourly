require "rails_helper"

RSpec.describe ChatResponseRunner, "cancellation" do
  let(:user) { User.create!(email: "stop-runner@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Local support") }
  let(:response) { ChatResponse.enqueue!(chat: chat, content: "Find free meals", model: chat.model_id, provider: chat.provider) }
  let(:context) { instance_double(RagContext) }
  let(:result) { RagContext::Result.new(instructions: "Private reference instructions", documents: []) }

  before do
    allow(ChatResponseJob).to receive(:perform_later).and_return(true)
    allow(RagContext).to receive(:new).and_return(context)
    allow(context).to receive(:augment).and_return(result)
    allow(Rails.error).to receive(:report)
    response
  end

  # Exercise the real SDK stream callbacks and placeholder cleanup. Only the
  # HTTP provider boundary is replaced; these are not mocked Chat#complete calls.
  def provider_complete(&block)
    allow_any_instance_of(chat.to_llm.provider.class).to receive(:complete, &block)
  end

  def chunk(content)
    RubyLLM::Chunk.new(role: :assistant, content: content)
  end

  def answer(content)
    RubyLLM::Message.new(role: :assistant, content: content, model: chat.model_id)
  end

  it "never looks up resources or calls the provider for a queued stop" do
    response.cancel!
    expect(context).not_to receive(:augment)
    provider_complete { raise "The provider must not run" }

    described_class.new(response.id).call

    expect(response.reload).to be_cancelled
    expect(chat.messages.where(role: "assistant")).to be_empty
  end

  it "acknowledges a stop during retrieval without starting the provider" do
    allow(context).to receive(:augment) do
      ChatResponse.find(response.id).cancel!
      result
    end
    provider_complete { raise "The provider must not run" }

    described_class.new(response.id).call

    expect(response.reload).to be_cancelled
    expect(chat.messages.where(role: "assistant")).to be_empty
    expect(Rails.error).not_to have_received(:report)
  end

  it "removes the empty placeholder when stopped before the first chunk" do
    provider_complete do |_provider, _messages, **_options, &stream|
      ChatResponse.find(response.id).cancel!
      stream.call(chunk("This must not appear"))
      answer("This must not appear")
    end

    described_class.new(response.id).call

    expect(response.reload).to be_cancelled
    expect(response.assistant_message).to be_nil
    expect(chat.messages.where(role: "assistant")).to be_empty
    expect(Rails.error).not_to have_received(:report)
  end

  it "keeps only text received before Stop and leaves the next response unaffected" do
    provider_complete do |_provider, _messages, **_options, &stream|
      stream.call(chunk("A useful partial answer"))
      ChatResponse.find(response.id).cancel!
      stream.call(chunk(" unwanted late text"))
      answer("A useful partial answer unwanted late text")
    end

    described_class.new(response.id).call

    expect(response.reload).to be_cancelled
    expect(response.assistant_message.content).to eq("A useful partial answer")
    expect(chat.messages.where(role: "user").count).to eq(1)
    expect(Rails.error).not_to have_received(:report)

    next_response = ChatResponse.enqueue!(chat: chat, content: "Another question", model: chat.model_id, provider: chat.provider)
    provider_complete do |_provider, _messages, **_options, &stream|
      stream.call(chunk("A new answer"))
      answer("A new answer")
    end
    described_class.new(next_response.id).call

    expect(next_response.reload).to be_completed
    expect(next_response.assistant_message.content).to eq("A new answer")
  end

  it "acknowledges a final-chunk stop without marking the response completed" do
    provider_complete do |_provider, _messages, **_options, &stream|
      stream.call(chunk("A partial answer"))
      ChatResponse.find(response.id).cancel!
      answer("A partial answer")
    end

    described_class.new(response.id).call

    expect(response.reload).to be_cancelled
    expect(response.assistant_message.content).to eq("A partial answer")
    expect(Rails.error).not_to have_received(:report)
  end

  it "does not recreate a partial record deleted with the conversation" do
    provider_complete do |_provider, _messages, **_options, &stream|
      stream.call(chunk("A partial answer"))
      Chat.find(chat.id).destroy!
      stream.call(chunk(" unwanted late text"))
      answer("A partial answer unwanted late text")
    end

    expect { described_class.new(response.id).call }.not_to raise_error

    expect(ChatResponse.exists?(response.id)).to be(false)
    expect(Message.where(chat_id: chat.id)).to be_empty
    expect(Rails.error).not_to have_received(:report)
  end
end
