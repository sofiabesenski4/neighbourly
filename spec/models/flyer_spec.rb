require "rails_helper"

RSpec.describe Flyer, type: :model do
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:shelters) { Category.create!(name: "Shelters") }

  it "distinguishes omitted resource details from clearing every checkbox" do
    expect(described_class.new.selected_details).to eq(%w[service address distance phone eligibility notes intake])
    expect(described_class.new(details: [""]).selected_details).to eq([])
    expect(described_class.new(details: ["", "phone", "phone"]).selected_details).to eq(["phone"])
  end

  it "is valid with known categories" do
    flyer = Flyer.new(categories: [meals.id.to_s, shelters.id.to_s])

    expect(flyer).to be_valid
  end

  it "accepts no category filters" do
    flyer = Flyer.new(categories: [])

    expect(flyer).to be_valid
    expect(flyer.categories).to be_empty
  end

  # The place to measure distances from. It's only a text check here: the lookup
  # happens when printing, so that validating never calls an outside service.
  describe "near" do
    it "is optional" do
      expect(Flyer.new.near).to be_nil
      expect(Flyer.new).to be_valid
    end

    it "treats blank text as no location and trims the rest" do
      expect(Flyer.new(near: "   ").near).to be_nil
      expect(Flyer.new(near: " 919 Pandora Ave ").near).to eq("919 Pandora Ave")
    end

    it "rejects unreasonably long text" do
      expect(Flyer.new(near: "a" * 201)).not_to be_valid
    end

    it "doesn't look anything up while validating" do
      expect(Geocoder).not_to receive(:locate)

      Flyer.new(near: "919 Pandora Ave").valid?
    end
  end

  # Coordinates from "Use my location", submitted through hidden form fields as text.
  describe "device location" do
    it "is optional, and treats blank fields as no location" do
      flyer = Flyer.new(lat: "", lng: " ")

      expect(flyer).to be_valid
      expect(flyer.coordinates).to be_nil
    end

    it "reads coordinates, rounded to about 100 m" do
      expect(Flyer.new(lat: "48.42711", lng: "-123.35776").coordinates)
        .to eq(GeoPoint.new(lat: 48.427, lng: -123.358))
    end

    it "rejects one coordinate without the other" do
      expect(Flyer.new(lat: "48.42")).not_to be_valid
      expect(Flyer.new(lng: "-123.35")).not_to be_valid
    end

    it "rejects text that isn't a number" do
      flyer = Flyer.new(lat: "north", lng: "-123.35")

      expect(flyer).not_to be_valid
      expect(flyer.errors.full_messages.join).to include("couldn't read your device's location")
    end

    it "rejects positions that don't exist" do
      expect(Flyer.new(lat: "91", lng: "-123.35")).not_to be_valid
      expect(Flyer.new(lat: "48.42", lng: "181")).not_to be_valid
      expect(Flyer.new(lat: "Infinity", lng: "-123.35")).not_to be_valid
    end
  end

  it "rejects categories that are not offered" do
    flyer = Flyer.new(categories: [meals.id.to_s, "spaceships"])

    expect(flyer).not_to be_valid
    expect(flyer.errors[:categories].first).to include("spaceships")
  end

  describe "organizations" do
    let(:organization) { Organization.create!(name: "Our Place Society") }

    it "offers only organizations with a service a printout could list" do
      Organization.create!(name: "No services yet")
      closed_only = Organization.create!(name: "Closed Society")
      Source.form_entry_source.services.create!(name: "Lunch", organization: organization)
      Source.form_entry_source.services.create!(name: "Shut", organization: closed_only, closed: true)

      expect(Flyer.available_organizations).to eq(organization.id.to_s => "Our Place Society")
    end

    it "accepts an offered organization and rejects others" do
      Source.form_entry_source.services.create!(name: "Lunch", organization: organization)

      expect(Flyer.new(organizations: ["", organization.id, organization.id.to_s])).to be_valid.and have_attributes(organizations: [organization.id.to_s])
      expect(Flyer.new(organizations: ["0"]).tap(&:valid?).errors[:organizations].first).to include("0")
    end

    it "includes chosen organizations in the filters" do
      Source.form_entry_source.services.create!(name: "Lunch", organization: organization)

      expect(Flyer.new.filters).not_to have_key(:organizations)
      expect(Flyer.new(organizations: [organization.id]).filters).to include(organizations: [organization.id.to_s])
    end
  end

  it "drops blank values and duplicates from the selection" do
    flyer = Flyer.new(categories: ["", meals.id, meals.id.to_s])

    expect(flyer.categories).to eq([meals.id.to_s])
  end

  it "offers database categories in name order and keeps IDs after a rename" do
    shelters.update!(name: "Emergency shelter")

    expect(Flyer.available_categories.to_a).to eq([[shelters.id.to_s, "Emergency shelter"], [meals.id.to_s, "Meals"]])
  end

  it "rejects deleted categories and malformed IDs without coercion" do
    deleted_id = shelters.id.to_s
    shelters.destroy!

    [deleted_id, "#{meals.id}oops", "0#{meals.id}", meals.name].each do |invalid|
      expect(Flyer.new(categories: [invalid])).not_to be_valid
    end
  end
end
