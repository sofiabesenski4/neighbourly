require "rails_helper"

RSpec.describe Flyer, type: :model do
  it "is valid with known categories" do
    flyer = Flyer.new(categories: ["food", "shelter"])

    expect(flyer).to be_valid
  end

  it "accepts no category filters" do
    flyer = Flyer.new(categories: [])

    expect(flyer).to be_valid
    expect(flyer.categories).to be_empty
  end

  it "rejects categories that are not offered" do
    flyer = Flyer.new(categories: ["food", "spaceships"])

    expect(flyer).not_to be_valid
    expect(flyer.errors[:categories].first).to include("spaceships")
  end

  it "drops blank values and duplicates from the selection" do
    flyer = Flyer.new(categories: ["", "food", "food"])

    expect(flyer.categories).to eq(["food"])
  end

  it "offers every resource category through available_categories" do
    expect(Flyer.available_categories.keys).to eq(ResourceCategory.all.map(&:key))
    expect(Flyer.available_categories).to include("food" => "Food", "harm_reduction" => "Harm reduction")
  end
end
