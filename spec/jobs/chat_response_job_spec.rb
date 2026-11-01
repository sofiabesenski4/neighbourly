require "rails_helper"

RSpec.describe ChatResponseJob, type: :job do
  include ActiveJob::TestHelper

  let(:user) { User.create!(email: "test@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:rag_context) { instance_double(RagContext) }
  let(:chunk) { double("chunk", content: "Hello!") }

  before do
    allow(RagContext).to receive(:new).and_return(rag_context)
    allow(rag_context).to receive(:augment).and_return(
      RagContext::Result.new(instructions: nil, documents: [])
    )

    # Stub chat.ask to yield a single chunk
    allow_any_instance_of(Chat).to receive(:ask).and_yield(chunk)

    # Stub the broadcasts
    chat.messages.create!(role: "assistant", content: "")
    allow_any_instance_of(Message).to receive(:broadcast_append_chunk)
    allow_any_instance_of(Message).to receive(:broadcast_rag_context)
  end

  it "augments the prompt with RAG context" do
    described_class.perform_now(chat.id, "Where are shelters?")

    expect(rag_context).to have_received(:augment).with("Where are shelters?")
  end

  it "passes only the original question to chat.ask" do
    expect_any_instance_of(Chat).to receive(:ask).with("Where are shelters?")
    described_class.perform_now(chat.id, "Where are shelters?")
  end

  it "does not add reference instructions when no documents are found" do
    expect_any_instance_of(Chat).not_to receive(:with_instructions)

    described_class.perform_now(chat.id, "Where are shelters?")
  end

  it "queues a title after a successful reply" do
    expect {
      described_class.perform_now(chat.id, "Where are shelters?")
    }.to have_enqueued_job(ChatTitleJob).with(chat.id)
  end

  it "does not queue another title once one has been generated" do
    chat.update!(title: "Local shelter options")

    expect {
      described_class.perform_now(chat.id, "Where are shelters?")
    }.not_to have_enqueued_job(ChatTitleJob)
  end

  context "when RAG documents are found" do
    let(:source) { Source.create!(name: "Test Source", url: "https://example.com", source_type: "html") }
    let(:documents) do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.1))
      [Document.create!(content: "Shelter info", source: source)]
    end

    before do
      allow(rag_context).to receive(:augment).and_return(
        RagContext::Result.new(instructions: "reference instructions", documents: documents)
      )
      chat.messages.create!(role: "user", content: "Where are shelters?")
    end

    it "keeps reference instructions in the model context without saving or broadcasting them" do
      allow_any_instance_of(Chat).to receive(:ask).and_call_original
      # Stop at the generation boundary, exercising RubyLLM's real message
      # persistence and context assembly without making a provider request.
      expect_any_instance_of(Chat).to receive(:complete) do |record|
        expect(record.messages.where(role: "user").last.content).to eq("Where are shelters?")
        expect(record.messages.where(role: "system")).to be_empty
        expect(record.to_llm.messages.select { |message| message.role == :system }.map(&:content))
          .to include("reference instructions")
        expect(record.to_llm.messages.last.content).to eq("Where are shelters?")
      end

      expect {
        perform_enqueued_jobs do
          described_class.perform_now(chat.id, "Where are shelters?")
        end
      }.to have_broadcasted_to("chat_#{chat.id}").with(
        satisfy("shows the original question without reference instructions") do |payload|
          payload.include?('action="append"') && payload.include?("Where are shelters?") && !payload.include?("reference instructions")
        end
      )

      expect(chat.messages.pluck(:content)).not_to include("reference instructions")
    end

    it "preserves the original question when generation fails" do
      allow_any_instance_of(Chat).to receive(:ask).and_call_original
      allow_any_instance_of(Chat).to receive(:complete).and_raise(RubyLLM::Error, "API down")

      expect {
        described_class.perform_now(chat.id, "Where are shelters?")
      }.to raise_error(RubyLLM::Error)

      expect(chat.messages.where(role: "user").last.content).to eq("Where are shelters?")
      expect(chat.messages.where(role: "system")).to be_empty
      expect(chat.messages.pluck(:content)).not_to include("reference instructions")
    end

    it "associates documents and broadcasts RAG context" do
      described_class.perform_now(chat.id, "Where are shelters?")

      user_msg = chat.messages.where(role: "user").last
      assistant_msg = chat.messages.where(role: "assistant").last
      expect(user_msg.rag_documents).to eq(documents)
      expect(assistant_msg.rag_documents).to eq(documents)
    end
  end

  context "when the model cannot reply" do
    it "uses the same alert ID for repeated failures so Turbo replaces the previous alert" do
      allow_any_instance_of(Chat).to receive(:ask).and_raise(RubyLLM::Error, "API down")

      expect {
        2.times do
          expect { described_class.perform_now(chat.id, "Hello") }.to raise_error(RubyLLM::Error)
        end
      }.to have_broadcasted_to("chat_#{chat.id}").with(
        a_string_including('action="append"', 'target="messages"', "id=\"chat_#{chat.id}_reply_failed\"")
      ).exactly(2).times
    end

    it "removes the failure alert after a successful retry" do
      allow_any_instance_of(Chat).to receive(:ask).and_raise(RubyLLM::Error, "API down")
      expect { described_class.perform_now(chat.id, "Hello") }.to raise_error(RubyLLM::Error)

      allow_any_instance_of(Chat).to receive(:ask).and_yield(chunk)

      expect {
        described_class.perform_now(chat.id, "Hello again")
      }.to have_broadcasted_to("chat_#{chat.id}").with(
        a_string_including('action="remove"', "target=\"chat_#{chat.id}_reply_failed\"")
      )
    end

    [RubyLLM::BadRequestError.new("Bad request"), Faraday::ConnectionFailed.new("Connection refused")].each do |error|
      it "tells the chat after a #{error.class}" do
        allow_any_instance_of(Chat).to receive(:ask).and_raise(error)

        expect {
          described_class.perform_now(chat.id, "Hello")
        }.to raise_error(error.class)
          .and have_broadcasted_to("chat_#{chat.id}").with(a_string_including("the assistant couldn't reply"))
      end
    end
  end

  context "when looking up local resources fails" do
    [
      RubyLLM::Error.new("embedding provider unavailable"),
      Faraday::TimeoutError.new("timed out")
    ].each do |error|
      context "with #{error.class}" do
        before do
          allow(rag_context).to receive(:augment).and_raise(error)
          allow(Rails.error).to receive(:report)
        end

        it "does not ask the LLM" do
          expect_any_instance_of(Chat).not_to receive(:ask)
          described_class.perform_now(chat.id, "Where are shelters?")
        end

        it "saves the user's message and an apology asking them to start a new chat" do
          described_class.perform_now(chat.id, "Where are shelters?")

          expect(chat.messages.where(role: "user").last.content).to eq("Where are shelters?")
          expect(chat.messages.where(role: "assistant").last.content).to eq(described_class::FALLBACK_RESPONSE)
        end

        it "reports the error" do
          described_class.perform_now(chat.id, "Where are shelters?")

          expect(Rails.error).to have_received(:report).with(error, context: {chat_id: chat.id})
        end
      end
    end
  end

  context "when the model cannot reply" do
    let(:use_rag) { false }

    [RubyLLM::BadRequestError.new("Bad request"), Faraday::ConnectionFailed.new("Connection refused")].each do |error|
      it "tells the chat after a #{error.class}" do
        allow_any_instance_of(Chat).to receive(:ask).and_raise(error)

        expect {
          described_class.perform_now(chat.id, "Hello")
        }.to raise_error(error.class)
          .and have_broadcasted_to("chat_#{chat.id}").with(a_string_including("the assistant couldn't reply"))
      end
    end
  end
end
