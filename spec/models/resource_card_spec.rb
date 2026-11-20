require "rails_helper"

RSpec.describe ResourceCard do
  let(:source) { Source.new(name: "Guide", source_type: "csv") }

  def service(name: "Meal program", address: nil, **attributes)
    Service.new(name: name, source: source, **attributes).tap do |service|
      service.build_address(**address) if address
    end
  end

  def card(...)
    described_class.new(service(...))
  end

  # The Distance row a printed card gets when someone enters a location. 0.01 degrees
  # of latitude is about 1.11 km, which makes the expected text easy to work out: minutes
  # are km × 1.3 (following streets) × 12 (walking at 5 km/h).
  describe "distance from an origin" do
    let(:origin) { FlyerOrigin.new(label: "Here", point: GeoPoint.new(lat: 48.42, lng: -123.36)) }

    def distance_row(address, origin: self.origin)
      described_class.new(service(address: address), origin: origin).fields.find { |field| field[:label] == "Distance" }
    end

    it "shows the distance and walking time" do
      expect(distance_row({lat: 48.43, lng: -123.36})[:value])
        .to eq("1.1 km straight-line, about 17 min walk")
    end

    it "uses hours for long walks" do
      expect(distance_row({lat: 48.52, lng: -123.36})[:value])
        .to eq("11.1 km straight-line, about 2 hr 53 min walk")
    end

    it "doesn't claim a distance of zero for a place next door" do
      expect(distance_row({lat: 48.42, lng: -123.36})[:value])
        .to eq("Under 0.1 km straight-line, about 1 min walk")
    end

    it "follows the address, so the location details stay together" do
      labels = described_class.new(service(hours: "Daily", address: {street_address: "919 Pandora Ave", lat: 48.43, lng: -123.36}),
        origin: origin).fields.map { |field| field[:label] }

      expect(labels).to eq(["Address", "Distance", "Hours"])
    end

    it "has no row for a service whose location isn't known" do
      expect(distance_row({street_address: "919 Pandora Ave"})).to be_nil
    end

    it "has no row for a service with no address" do
      expect(described_class.new(service, origin: origin).fields).to be_empty
    end

    it "has no row when no location was entered" do
      expect(distance_row({lat: 48.43, lng: -123.36}, origin: nil)).to be_nil
    end

    it "has no row when the geocoder was down" do
      unavailable = FlyerOrigin.new(label: "Here", point: nil)

      expect(distance_row({lat: 48.43, lng: -123.36}, origin: unavailable)).to be_nil
    end
  end

  it "uses database category names for service labels" do
    listing = service
    listing.categories.build(name: "Meals")

    expect(described_class.new(listing).fields).to include({label: "Services", value: "Meals"})
  end

  it "omits complete fields whose values are missing" do
    expect(card.fields).to be_empty
    expect(card(hours: " ", email: "", additional_details: {notes: " ", intake: nil, languages: []}).fields).to be_empty
  end

  it "uses the agreed labels, puts Intake after Notes, and prints only provided dates" do
    fields = card(description: "Meals", hours: "Noon", address: {street_address: "123 Main St", city: "Victoria"},
      additional_details: {notes: "Call ahead", intake_info: "Walk in", last_updated_at: "2026-10-15"}).fields

    expect(fields.map { |field| field[:label] }).to eq(["Services", "Address", "Hours", "Notes", "Intake", "Last updated"])
    expect(fields.find { |field| field[:label] == "Address" }[:value]).to eq("123 Main St, Victoria")
    expect(fields.map { |field| field[:label] }).not_to include("Last checked", "Information source")
  end

  it "shows the city alone when there is no street address" do
    expect(card(address: {city: "Victoria"}).fields).to eq([{label: "City", value: "Victoria"}])
  end

  it "labels the description Services" do
    expect(card(description: "Free hot meals").fields)
      .to include({label: "Services", value: "Free hot meals"})
  end

  # An import keeps each extra column under its own header.
  it "finds imported details whatever their headers' case and spacing" do
    fields = card(additional_details: {"Intake Info" => "Call first", "NOTES" => "Bring ID", "Ages" => "19+",
                                       "Gender" => "Women", "Languages" => "French"}).fields

    expect(fields).to eq([
      {label: "Ages served", value: "19+"},
      {label: "Eligibility", value: "Women"},
      {label: "Languages", value: "French"},
      {label: "Notes", value: "Bring ID"},
      {label: "Intake", value: "Call first"}
    ])
  end

  it "shows the age range and genders saved by the resource form" do
    fields = card(additional_details: {"age_range" => {"min" => 19, "max" => nil}, "gender" => ["women", "non-binary"]}).fields

    expect(fields).to include({label: "Ages served", value: "19+"}, {label: "Eligibility", value: "women, non-binary"})
  end

  it "says when and how the service was last confirmed, without who" do
    confirmed = card(confirmed_at: Time.zone.parse("2026-11-20 10:00"), confirmation_method: "phone",
      confirmed_by: User.new(email: "checker@example.com"))

    expect(confirmed.fields).to eq([{label: "Last confirmed", value: "Nov 20, 2026 by phone"}])
    expect(confirmed.as_json.to_json).not_to include("checker@example.com")
  end

  it "puts separate phone numbers on separate lines" do
    expect(card(phone: "250-555-0100, 250-555-0101").fields)
      .to include({label: "Phone", value: "250-555-0100\n250-555-0101"})
  end

  it "preserves zero and false rather than treating them as missing" do
    expect(card(additional_details: {notes: false, age_range: {min: 0, max: 18}}).fields)
      .to include({label: "Notes", value: "false"}, {label: "Ages served", value: "0-18"})
  end

  it "does not expose other details, embeddings, or administrative fields" do
    data = card(additional_details: {notes: "Public note", private_email: "secret@example.org", internal_review: "Hidden"}).as_json

    expect(data.keys).to eq([:id, :title, :fields])
    expect(data.to_json).not_to include("secret@example.org", "Hidden", "embedding")
  end

  it "uses a real supplied source URL without inventing one" do
    source.url = "https://example.org/guide"
    expect(card.fields).to include({label: "Information source", value: source.url})
  end
end
