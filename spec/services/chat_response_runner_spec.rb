require "rails_helper"

RSpec.describe ChatResponseRunner do
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "response-runner@example.com", password: "password123") }
  let(:chat) { user.chats.create!(title: "Local support") }
  let(:response) { ChatResponse.enqueue!(chat: chat, content: "Where can I find meals?", model: chat.model_id, provider: chat.provider) }
  let(:context) { instance_double(RagContext) }
  let(:documents) { [] }
  let(:result) { RagContext::Result.new(instructions: "Private reference instructions", documents: documents) }

  before do
    allow(RagContext).to receive(:new).and_return(context)
    allow(context).to receive(:augment).and_return(result)
    allow(Rails.error).to receive(:report)
    response
  end

  # Stub only the provider boundary. RubyLLM still creates, streams, saves, and
  # cleans up its own assistant record through its real persistence callbacks.
  def provider_complete(&block)
    allow_any_instance_of(chat.to_llm.provider.class).to receive(:complete, &block)
  end

  def chunk(content)
    RubyLLM::Chunk.new(role: :assistant, content: content)
  end

  def answer(content)
    RubyLLM::Message.new(role: :assistant, content: content, model: chat.model_id, input_tokens: 10, output_tokens: 5)
  end

  it "completes the saved question without persisting reference instructions or a duplicate user message" do
    captured_messages = nil
    provider_complete do |_provider, messages, **_options, &stream|
      captured_messages = messages
      stream.call(chunk("Try "))
      stream.call(chunk("the community kitchen."))
      answer("Try the community kitchen.")
    end

    described_class.new(response.id).call

    expect(response.reload).to be_completed
    expect(response.assistant_message.content).to eq("Try the community kitchen.")
    expect(response.finished_at).to be_present
    expect(chat.messages.where(role: "user").count).to eq(1)
    expect(chat.messages.where(role: "system")).to be_empty
    expect(captured_messages.select { |message| message.role == :system }.map(&:content)).to include("Private reference instructions")
    expect(captured_messages.select { |message| message.role == :user }.map(&:content)).to eq(["Where can I find meals?"])
  end

  it "does not execute duplicate jobs once the response has been claimed" do
    response.claim!
    expect(context).not_to receive(:augment)

    described_class.new(response.id).call
  end

  it "keeps a streamed partial answer when the provider fails" do
    error = RubyLLM::Error.new("Provider failed after sending a chunk")
    provider_complete do |_provider, _messages, **_options, &stream|
      stream.call(chunk("A partial answer"))
      raise error
    end

    expect { described_class.new(response.id).call }.not_to raise_error

    expect(response.reload).to be_failed
    expect(response.assistant_message).to be_present
    expect(response.assistant_message.content).to eq("A partial answer")
    expect(response.error_message).to eq(ChatResponse::FAILED_MESSAGE)
    expect(chat.messages.where(role: "user").count).to eq(1)
    expect(Rails.error).to have_received(:report).with(error, context: {chat_id: chat.id, chat_response_id: response.id})
  end

  it "removes empty SDK placeholders on an early provider failure" do
    provider_complete { raise Faraday::ConnectionFailed, "Provider unavailable" }

    described_class.new(response.id).call

    expect(response.reload).to be_failed
    expect(response.assistant_message).to be_nil
    expect(chat.messages.where(role: "assistant")).to be_empty
    expect(chat.messages.where(role: "user").count).to eq(1)
  end

  it "reports lookup failure without creating an apology as a grounded answer" do
    allow(context).to receive(:augment).and_raise(Faraday::TimeoutError, "Lookup unavailable")

    described_class.new(response.id).call

    expect(response.reload).to be_failed
    expect(response.error_message).to eq(ChatResponse::LOOKUP_FAILED_MESSAGE)
    expect(chat.messages.where(role: "assistant")).to be_empty
  end

  it "marks unexpected failures before re-raising them for job reporting" do
    allow(context).to receive(:augment).and_raise(ArgumentError, "Unexpected failure")

    expect { described_class.new(response.id).call }.to raise_error(ArgumentError, "Unexpected failure")
    expect(response.reload).to be_failed
  end

  context "with retrieved documents" do
    let(:source) { Source.create!(name: "Community directory", url: "https://example.com", source_type: "html") }
    let(:documents) do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.1))
      [Document.create!(source: source, title: "Community kitchen", content: "Free meals daily")]
    end

    it "associates the retrieved documents with the original question and final answer" do
      provider_complete do |_provider, _messages, **_options, &stream|
        stream.call(chunk("Try the community kitchen."))
        answer("Try the community kitchen.")
      end

      described_class.new(response.id).call

      expect(response.reload.user_message.rag_documents).to match_array(documents)
      expect(response.assistant_message.rag_documents).to match_array(documents)
    end
  end
end
