require "rails_helper"

RSpec.describe ContentPipeline::Chunker do
  describe ".call" do
    context "when text fits within a single chunk" do
      it "returns the text as a single-element array" do
        text = "Short text."
        expect(described_class.call(text)).to eq(["Short text."])
      end

      it "returns a single chunk for text exactly at the max length" do
        text = "a" * described_class::MAX_CHUNK_LENGTH
        expect(described_class.call(text)).to eq([text])
      end
    end

    context "when text exceeds the max chunk length" do
      it "splits into multiple chunks" do
        text = "a" * 3000
        chunks = described_class.call(text)

        expect(chunks.length).to be > 1
      end

      it "keeps each chunk within the max length" do
        text = "a" * 5000
        chunks = described_class.call(text)

        chunks.each do |chunk|
          expect(chunk.length).to be <= described_class::MAX_CHUNK_LENGTH
        end
      end

      it "creates overlap between consecutive chunks" do
        sentences = (1..10).map { |i| "I love pepperoni #{i}." }
        text = sentences.join(" ")
        chunks = described_class.call(text, max_chunk_length: 80, overlap_length: 20)

        expect(chunks[0]).to eq("I love pepperoni 1. I love pepperoni 2. I love pepperoni 3. I love pepperoni 4.")
        expect(chunks[1]).to eq("I love pepperoni 4. I love pepperoni 5. I love pepperoni 6. I love pepperoni 7.")
        expect(chunks[1]).to start_with("I love pepperoni 4.")
        expect(chunks[0]).to end_with("I love pepperoni 4.")
      end

      it "covers the entire input text" do
        sentences = (1..30).map { |i| "Sentence number #{i}." }
        text = sentences.join(" ")
        chunks = described_class.call(text)

        sentences.each do |sentence|
          expect(chunks.any? { |c| c.include?(sentence) }).to be(true),
            "Expected to find #{sentence.inspect} in at least one chunk"
        end
      end
    end

    context "sentence boundary breaking" do
      it "breaks at a period when one exists past the midpoint" do
        first_half = "a" * 800 + ". "
        second_half = "b" * 800
        text = first_half + second_half

        chunks = described_class.call(text)

        expect(chunks.first).to end_with(".")
      end

      it "breaks at a newline when one exists past the midpoint" do
        first_half = "a" * 800 + "\n"
        second_half = "b" * 800
        text = first_half + second_half

        chunks = described_class.call(text)

        expect(chunks.first).to end_with("a")
      end

      it "does not break at a boundary in the first half of the chunk" do
        early_break = "a" * 100 + ". " + "b" * 1600
        chunks = described_class.call(early_break)

        expect(chunks.first.length).to be > described_class::MAX_CHUNK_LENGTH / 2
      end
    end

    context "whitespace handling" do
      it "strips whitespace from chunks" do
        text = "  content  " + " " * 1500 + "more content"
        chunks = described_class.call(text)

        chunks.each do |chunk|
          expect(chunk).to eq(chunk.strip)
        end
      end

      it "omits blank chunks" do
        text = "content." + " " * 1500 + "more content."
        chunks = described_class.call(text)

        chunks.each do |chunk|
          expect(chunk).not_to be_empty
        end
      end
    end

    context "with realistic resource text" do
      let(:text) do
        paragraphs = [
          "Harbour Street Community Centre provides meals Monday through Friday from 11am to 1pm. " \
          "No ID or referral is required. The centre is located at 300 Harbour Street, Victoria.",
          "The Mustard Seed Food Bank distributes groceries every Tuesday and Thursday. " \
          "Clients should bring their own bags. Registration is available on-site.",
          "Lantern House Society operates an emergency shelter with 45 beds available nightly. " \
          "Intake begins at 7pm. Priority is given to those most vulnerable.",
          "Island Health offers free mental health drop-in counselling at the downtown clinic. " \
          "Sessions are 30 minutes. No appointment needed, first come first served."
        ]
        paragraphs.join("\n\n") * 5
      end

      it "produces chunks that each contain coherent sentences" do
        chunks = described_class.call(text)

        chunks.each do |chunk|
          expect(chunk).to match(/[a-zA-Z]/)
        end
      end

      it "does not lose any paragraph content" do
        chunks = described_class.call(text)
        reassembled = chunks.join(" ")

        expect(reassembled).to include("Harbour Street Community Centre")
        expect(reassembled).to include("Mustard Seed Food Bank")
        expect(reassembled).to include("Lantern House Society")
        expect(reassembled).to include("Island Health")
      end
    end
  end
end
