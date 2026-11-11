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
      expect(chunk[:categories]).to eq(["24 Hour", "Pet Friendly"])
    end

    it "stores structured metadata, with the location and phone on the address" do
      chunk = parser.parse(shelter_json).first

      expect(chunk[:address]).to include(city: "vancouver", phone: "604-555-1234")
      expect(chunk[:metadata]).not_to include(:city, :address, :phone, :lat, :lng)
      expect(chunk[:metadata][:gender]).to eq(["men"])
      expect(chunk[:categories]).to eq(["24 Hour", "Pet Friendly"])
      expect(chunk[:metadata][:notes]).to eq("No drugs or alcohol")
      expect(chunk[:metadata][:intake_info]).to eq("First come first served")
    end

    it "preserves supplied print fields without inventing missing values" do
      record = JSON.parse(shelter_json).first.merge(
        "hours" => "Every day, noon-1pm", "email" => "info@example.org",
        "website" => "https://example.org", "description" => "A hot lunch",
        "last_updated_at" => "2026-10-15", "source_url" => "https://example.org/guide"
      )

      metadata = parser.parse([record].to_json).first.fetch(:metadata)

      %w[hours email website description last_updated_at source_url].each do |key|
        expect(metadata[key.to_sym]).to eq(record[key])
      end
      expect(parser.parse(shelter_json).first[:metadata]).not_to have_key(:last_updated_at)
    end

    it "preserves source taxonomy names for database category assignment" do
      json = [{
        "id" => 1,
        "post_title" => "Drop-in Centre",
        "taxonomies" => [{"name" => "Meals"}, {"name" => "Showers"}, {"name" => "Pet Friendly"}]
      }].to_json

      chunk = parser.parse(json).first

      expect(chunk[:categories]).to eq(["Meals", "Showers", "Pet Friendly"])
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
      expect(chunk[:address]).to include(street_address: nil, city: nil, lat: nil, lng: nil)
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
      expect(chunk[:address]).to include(street_address: "400 Cedar St", city: "vancouver", lat: nil, lng: nil)
    end
  end
end
