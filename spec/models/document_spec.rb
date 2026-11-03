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
    before do
      ["Shelters", "Meals"].each { |name| Category.find_or_create_by!(name: name) }
    end

    it "belongs to a source" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))

      doc = source.documents.create!(content: "test", external_id: "1")
      expect(doc.source).to eq(source)
    end

    it "shares categories between documents" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      first = source.documents.create!(content: "first", external_id: "1", category_names: ["Shelters"])
      second = source.documents.create!(content: "second", external_id: "2", category_names: ["Shelters"])

      expect(first.categories.first).to eq(second.categories.first)
    end

    it "ignores category names that are not in the categories table" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      document = source.documents.create!(
        content: "test",
        external_id: "unknown-category",
        category_names: ["unseeded"]
      )

      expect(document.categories).to be_empty
      expect(Category.exists?(name: "unseeded")).to be false
    end

    it "keeps categories when their document is deleted" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      document = source.documents.create!(content: "test", external_id: "orphan", category_names: ["Shelters"])
      category = document.categories.first

      document.destroy!

      expect(category.reload.documents).to be_empty
    end

    it "keeps categories that are still associated with other documents" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      first = source.documents.create!(content: "first", external_id: "first", category_names: ["Shelters"])
      second = source.documents.create!(content: "second", external_id: "second", category_names: ["Shelters"])
      category = first.categories.first

      first.destroy!

      expect(category.reload.documents).to eq([second])
    end

    it "keeps old categories after replacing a document's categories" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      document = source.documents.create!(content: "test", external_id: "replace", category_names: ["Shelters"])
      old_category = document.categories.first

      document.category_names = ["Meals"]

      expect(old_category.reload.documents).to be_empty
      expect(document.reload.category_names).to eq(["Meals"])
    end

    it "rolls back category replacement when the document save fails" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      document = source.documents.create!(content: "original", external_id: "rollback", category_names: ["Shelters"])
      old_category = document.categories.first
      allow(ContentPipeline::Embedder).to receive(:embed).and_raise(RubyLLM::Error.new("API down"))
      document.content = "updated"

      expect(document.save_with_category_names(["Meals"])).to be false

      expect(old_category.reload.documents).to eq([document])
      expect(Category.find_by!(name: "Meals").documents).to be_empty
      expect(document.reload.category_names).to eq(["Shelters"])
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

    it "prevents saving an empty provider embedding as a zero vector" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_call_original
      allow(RubyLLM).to receive(:embed).and_return(instance_double(RubyLLM::Embedding, vectors: []))

      doc = source.documents.build(content: "Will fail", external_id: "auto-empty")

      expect(doc.save).to be false
      expect(doc).not_to be_persisted
      expect(doc.embedding).to be_nil
      expect(doc.errors[:base]).to include(a_string_matching(/Failed to generate embedding.*empty vector/))
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
