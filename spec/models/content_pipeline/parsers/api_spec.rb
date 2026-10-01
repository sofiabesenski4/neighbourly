require "rails_helper"

RSpec.describe ContentPipeline::Parsers::Api do
  let(:source) { Source.new(name: "Shelters", url: "https://example.com/api", source_type: "api") }
  let(:parser) { described_class.new(source) }

  let(:shelter_json) do
    [
      {
        "id" => 1556,
        "post_title" => "Test Shelter",
        "location" => {
          "city" => {"value" => "vancouver", "label" => "Vancouver"},
          "street_address" => "123 Main St",
          "location" => {"lat" => 49.28, "lng" => -123.10}
        },
        "contact" => [{"contact" => {"phone_number" => "604-555-1234", "hidden" => false}}],
        "beds" => {"availability" => "Men: 5", "full" => false},
        "age_range" => {"min" => "19", "max" => ""},
        "gender" => [{"value" => "men", "label" => "Men"}],
        "taxonomies" => [{"name" => "24 Hour"}, {"name" => "Pet Friendly"}],
        "notes" => "No drugs or alcohol",
        "intake_info" => "First come first served",
        "closed" => false
      }
    ].to_json
  end

  describe "#parse" do
    it "returns an array of chunk hashes" do
      chunks = parser.parse(shelter_json)

      expect(chunks.size).to eq(1)
      chunk = chunks.first

      expect(chunk[:title]).to eq("Test Shelter")
      expect(chunk[:external_id]).to eq("1556")
      expect(chunk[:content]).to include("Test Shelter")
      expect(chunk[:content]).to include("City: Vancouver")
      expect(chunk[:content]).to include("Address: 123 Main St")
      expect(chunk[:content]).to include("Phone: 604-555-1234")
      expect(chunk[:content]).to include("Beds: Men: 5")
      expect(chunk[:content]).to include("Age range: 19+")
      expect(chunk[:content]).to include("Gender: Men")
      expect(chunk[:content]).to include("Categories: 24 Hour, Pet Friendly")
      expect(chunk[:content]).to include("Notes: No drugs or alcohol")
      expect(chunk[:content]).to include("Intake: First come first served")
    end

    it "stores structured metadata" do
      chunk = parser.parse(shelter_json).first

      expect(chunk[:metadata][:city]).to eq("vancouver")
      expect(chunk[:metadata][:phone]).to eq(["604-555-1234"])
      expect(chunk[:metadata][:gender]).to eq(["men"])
      expect(chunk[:metadata][:categories]).to eq(["24 Hour", "Pet Friendly"])
    end

    it "skips records without a post_title" do
      json = [{"id" => 1, "post_title" => nil}].to_json
      expect(parser.parse(json)).to be_empty
    end

    it "handles a single object (not wrapped in array)" do
      single = {"id" => 1, "post_title" => "Solo"}.to_json
      chunks = parser.parse(single)
      expect(chunks.size).to eq(1)
      expect(chunks.first[:title]).to eq("Solo")
    end

    it "marks full shelters in content" do
      json = [{"id" => 1, "post_title" => "Full Place", "beds" => {"full" => true}}].to_json
      chunk = parser.parse(json).first
      expect(chunk[:content]).to include("Currently full")
    end

    it "handles location set to false" do
      json = [{
        "id" => 99,
        "post_title" => "No Location Shelter",
        "location" => false
      }].to_json

      chunk = parser.parse(json).first

      expect(chunk[:content]).not_to include("City:")
      expect(chunk[:content]).not_to include("Address:")
      expect(chunk[:metadata][:lat]).to be_nil
      expect(chunk[:metadata][:lng]).to be_nil
      expect(chunk[:metadata][:city]).to be_nil
    end

    it "handles nested location.location set to false" do
      json = [{
        "id" => 1566,
        "post_title" => "St. John the Divine",
        "location" => {
          "city" => {"value" => "vancouver", "label" => "Vancouver"},
          "hidden" => false,
          "location" => false,
          "street_address" => "400 Cedar St"
        }
      }].to_json

      chunk = parser.parse(json).first

      expect(chunk[:content]).to include("City: Vancouver")
      expect(chunk[:content]).to include("Address: 400 Cedar St")
      expect(chunk[:metadata][:city]).to eq("vancouver")
      expect(chunk[:metadata][:address]).to eq("400 Cedar St")
      expect(chunk[:metadata][:lat]).to be_nil
      expect(chunk[:metadata][:lng]).to be_nil
    end
  end
end
