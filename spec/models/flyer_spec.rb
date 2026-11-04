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
