require "rails_helper"

RSpec.describe RagContext do
  let(:fake_vector) { Array.new(1536, 0.0).tap { |v| v[0] = 1.0 } }
  let(:rag_context) { described_class.new(limit: 3) }

  let(:source) { Source.create!(name: "BC 211 Shelters", url: "https://example.com/api", source_type: "api") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
  end

  describe "#augment" do
    context "when relevant documents exist" do
      before do
        source.documents.create!(
          content: "Test Shelter\nCity: Vancouver\nPhone: 604-555-1234",
          title: "Test Shelter",
          external_id: "1",
          embedding: fake_vector
        )
      end

      it "returns reference instructions separately from the user's question" do
        result = rag_context.augment("Where can I find shelter?")

        expect(result.instructions).to include("REFERENCE DOCUMENTS")
        expect(result.instructions).to include("Test Shelter")
        expect(result.instructions).to include("City: Vancouver")
        expect(result.instructions).to include("Source: BC 211 Shelters, URL: https://example.com/api")
        expect(result.instructions).not_to include("Where can I find shelter?")
      end

      it "returns the matched documents" do
        result = rag_context.augment("Where can I find shelter?")

        expect(result.documents.length).to eq(1)
        expect(result.documents.first.title).to eq("Test Shelter")
      end

      it "embeds the user's question to find relevant documents" do
        rag_context.augment("Where can I find shelter?")
        expect(ContentPipeline::Embedder).to have_received(:embed).with("Where can I find shelter?")
      end

      it "numbers multiple documents" do
        source.documents.create!(
          content: "Another Shelter\nCity: Victoria",
          title: "Another Shelter",
          external_id: "2",
          embedding: fake_vector
        )

        result = rag_context.augment("shelters?")
        expect(result.instructions).to include("[1]")
        expect(result.instructions).to include("[2]")
        expect(result.documents.length).to eq(2)
      end
    end

    context "when no documents exist at all" do
      it "returns no reference instructions" do
        result = rag_context.augment("Hello")
        expect(result.instructions).to be_nil
        expect(result.documents).to be_empty
      end
    end
  end
end
