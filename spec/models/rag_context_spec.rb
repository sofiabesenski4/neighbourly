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
        expect(result.instructions).to include("Source: BC 211 Shelters")
        expect(result.instructions).to include("[ref:#{source.documents.first.id}]")
        expect(result.instructions).not_to include("https://example.com/api")
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

      it "uses stable document IDs rather than retrieval positions" do
        source.documents.create!(
          content: "Another Shelter\nCity: Victoria",
          title: "Another Shelter",
          external_id: "2",
          embedding: fake_vector
        )

        result = rag_context.augment("shelters?")
        result.documents.each do |document|
          expect(result.instructions).to include("[ref:#{document.id}]")
        end
        expect(result.documents.length).to eq(2)
      end

      it "asks for supported reference markers without guessing source URLs" do
        instructions = rag_context.augment("shelters?").instructions.squish

        expect(instructions).to include("Cite a reference only when it supports the claim")
        expect(instructions).to include("Do not invent markers")
        expect(instructions).to include("Do not write, guess, or reconstruct reference URLs")
        expect(instructions).to include("do not comment on whether a URL is available")
      end

      it "limits answers to the reference documents without words of support" do
        instructions = rag_context.augment("shelters?").instructions.squish

        expect(instructions).to include("provide no general information based on your own knowledge")
        expect(instructions).to include("reaches out to the support team")
        expect(instructions).to include("DO NOT ADD ANY SORT OF HUMAN OPINION OR WORDS OF SUPPORT")
      end
    end

    context "when no documents exist at all" do
      it "still limits answers to the reference documents" do
        result = rag_context.augment("Hello")
        instructions = result.instructions.squish

        expect(instructions).to include("provide no general information based on your own knowledge")
        expect(instructions).to include("No reference documents matched this question.")
        expect(result.documents).to be_empty
      end
    end
  end
end
