require "rails_helper"

RSpec.describe Flyer, type: :model do
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:shelters) { Category.create!(name: "Shelters") }

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

  it "rejects categories that are not offered" do
    flyer = Flyer.new(categories: [meals.id.to_s, "spaceships"])

    expect(flyer).not_to be_valid
    expect(flyer.errors[:categories].first).to include("spaceships")
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
