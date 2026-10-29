require "rails_helper"

RSpec.describe ContentPipeline::Embedder do
  let(:embedder) { described_class.new }
  let(:fake_vector) { Array.new(1536, 0.5) }

  before do
    result = instance_double(RubyLLM::Embedding, vectors: fake_vector)
    allow(RubyLLM).to receive(:embed).and_return(result)
  end

  describe "#embed" do
    it "returns vectors from RubyLLM" do
      expect(embedder.embed("What shelters are available?")).to eq(fake_vector)
      expect(RubyLLM).to have_received(:embed).with("What shelters are available?", model: RubyLLM.config.default_embedding_model)
    end

    it "uses an explicitly selected embedding model" do
      described_class.new(model: "nomic-embed-text-cpu").embed("test input")

      expect(RubyLLM).to have_received(:embed).with("test input", model: "nomic-embed-text-cpu")
    end

    context "with a 768-dimensional playground embedding" do
      let(:fake_vector) { Array.new(768, 0.5) }

      it "preserves the native vector and pads it to the database dimensions" do
        vector = embedder.embed("test input")

        expect(vector).to eq(fake_vector + Array.new(768, 0.0))
        expect(fake_vector.size).to eq(768)
      end
    end

    context "with an embedding larger than the database supports" do
      let(:fake_vector) { Array.new(3072, 0.5) }

      it "raises an actionable error handled by the existing embedding failure flow" do
        expect { embedder.embed("test input") }.to raise_error(
          RubyLLM::Error, /returned 3072 dimensions; documents support at most 1536.*EMBEDDING_MODEL/
        )
      end
    end
  end

  describe ".embed" do
    it "provides a class-level shortcut" do
      expect(described_class.embed("test input")).to eq(fake_vector)
    end
  end
end
