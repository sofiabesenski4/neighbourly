require "rails_helper"

RSpec.describe ContentPipeline::Embedder do
  let(:embedder) { described_class.new }
  let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }

  describe "#embed" do
    it "returns vectors from RubyLLM" do
      result = instance_double(RubyLLM::Embedding, vectors: fake_vector)
      allow(RubyLLM).to receive(:embed).and_return(result)
      allow(RubyLLM).to receive(:models).and_return(instance_double(RubyLLM::Models, refresh: nil))

      expect(embedder.embed("What shelters are available?")).to eq(fake_vector)
    end
  end

  describe ".embed" do
    it "provides a class-level shortcut" do
      result = instance_double(RubyLLM::Embedding, vectors: fake_vector)
      allow(RubyLLM).to receive(:embed).and_return(result)
      allow(RubyLLM).to receive(:models).and_return(instance_double(RubyLLM::Models, refresh: nil))

      expect(described_class.embed("test input")).to eq(fake_vector)
    end
  end
end
