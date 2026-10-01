require "rails_helper"

RSpec.describe ChatResponseJob, type: :job do
  let(:user) { User.create!(email: "test@example.com", password: "password123") }
  let(:chat) { user.chats.create!(use_rag: use_rag) }
  let(:rag_context) { instance_double(RagContext) }
  let(:chunk) { double("chunk", content: "Hello!") }

  before do
    allow(RagContext).to receive(:new).and_return(rag_context)
    allow(rag_context).to receive(:augment).and_return(
      RagContext::Result.new(prompt: "augmented prompt", documents: [])
    )

    # Stub chat.ask to yield a single chunk
    allow_any_instance_of(Chat).to receive(:ask).and_yield(chunk)

    # Stub the broadcasts
    chat.messages.create!(role: "assistant", content: "")
    allow_any_instance_of(Message).to receive(:broadcast_append_chunk)
    allow_any_instance_of(Message).to receive(:broadcast_rag_context)
  end

  context "when use_rag is true" do
    let(:use_rag) { true }

    it "augments the prompt with RAG context" do
      described_class.perform_now(chat.id, "Where are shelters?")

      expect(rag_context).to have_received(:augment).with("Where are shelters?")
    end

    it "passes the augmented prompt to chat.ask" do
      expect_any_instance_of(Chat).to receive(:ask).with("augmented prompt")
      described_class.perform_now(chat.id, "Where are shelters?")
    end

    context "when RAG documents are found" do
      let(:source) { Source.create!(name: "Test Source", url: "https://example.com", source_type: "html") }
      let(:documents) do
        allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.1))
        [Document.create!(content: "Shelter info", source: source)]
      end

      before do
        allow(rag_context).to receive(:augment).and_return(
          RagContext::Result.new(prompt: "augmented prompt", documents: documents)
        )
        chat.messages.create!(role: "user", content: "Where are shelters?")
      end

      it "associates documents and broadcasts RAG context" do
        described_class.perform_now(chat.id, "Where are shelters?")

        user_msg = chat.messages.where(role: "user").last
        assistant_msg = chat.messages.where(role: "assistant").last
        expect(user_msg.rag_documents).to eq(documents)
        expect(assistant_msg.rag_documents).to eq(documents)
      end
    end
  end

  context "when use_rag is false" do
    let(:use_rag) { false }

    it "does not augment the prompt" do
      described_class.perform_now(chat.id, "Hello")

      expect(RagContext).not_to have_received(:new)
    end

    it "passes the original prompt to chat.ask" do
      expect_any_instance_of(Chat).to receive(:ask).with("Hello")
      described_class.perform_now(chat.id, "Hello")
    end
  end
end
