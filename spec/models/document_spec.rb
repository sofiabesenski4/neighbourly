require "rails_helper"

RSpec.describe Document, type: :model do
  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }

  describe "validations" do
    it "is valid with content and a source" do
      doc = source.documents.build(content: "Some content", external_id: "1")
      expect(doc).to be_valid
    end

    it "requires content" do
      doc = source.documents.build(content: nil, external_id: "1")
      expect(doc).not_to be_valid
      expect(doc.errors[:content]).to include("can't be blank")
    end
  end

  describe "associations" do
    it "belongs to a source" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))

      doc = source.documents.create!(content: "test", external_id: "1")
      expect(doc.source).to eq(source)
    end
  end

  describe "auto-embedding on save" do
    let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }

    before do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
    end

    it "generates an embedding automatically when content changes" do
      doc = source.documents.create!(content: "Initial content", external_id: "auto-1")
      expect(doc.embedding).to eq(fake_vector)
    end

    it "regenerates the embedding when content is updated" do
      doc = source.documents.create!(content: "Original", external_id: "auto-2")

      updated_vector = Array.new(1536) { rand(-1.0..1.0) }
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(updated_vector)

      doc.update!(content: "Updated content")
      expect(doc.embedding).to eq(updated_vector)
    end

    it "does not regenerate the embedding when content has not changed" do
      doc = source.documents.create!(content: "Stable content", external_id: "auto-3")

      doc.update!(title: "New title")
      expect(ContentPipeline::Embedder).to have_received(:embed).once
    end

    it "prevents saving when the embedding API fails" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_raise(RubyLLM::Error.new("API down"))

      doc = source.documents.build(content: "Will fail", external_id: "auto-4")
      expect(doc.save).to be false
      expect(doc.errors[:base]).to include(a_string_matching(/Failed to generate embedding/))
    end
  end

  describe ".search_by_similarity" do
    it "returns documents ordered by cosine similarity" do
      vec_a = Array.new(1536, 0.0)
      vec_a[0] = 1.0

      vec_b = Array.new(1536, 0.0)
      vec_b[1] = 1.0

      allow(ContentPipeline::Embedder).to receive(:embed).and_return(vec_a)
      source.documents.create!(content: "Doc A", external_id: "a")

      allow(ContentPipeline::Embedder).to receive(:embed).and_return(vec_b)
      source.documents.create!(content: "Doc B", external_id: "b")

      allow(ContentPipeline::Embedder).to receive(:embed).and_return(vec_a)
      results = Document.search_by_similarity("query along dimension 0", limit: 2)
      expect(results.first.content).to eq("Doc A")
      expect(results.last.content).to eq("Doc B")
    end
  end
end
