require "rails_helper"

RSpec.describe ResourceCategory do
  describe ".keys_for" do
    it "returns the categories the labels belong to" do
      expect(described_class.keys_for(["Meals", "Showers"])).to eq(["food", "hygiene"])
    end

    it "ignores case and surrounding whitespace" do
      expect(described_class.keys_for(["  meals ", "EMERGENCY SHELTER"])).to eq(["food", "shelter"])
    end

    it "returns each category once, in the order of .all" do
      expect(described_class.keys_for(["Showers", "Food bank", "Meals"])).to eq(["food", "hygiene"])
    end

    it "matches a category's own name" do
      expect(described_class.keys_for(["Food", "Shelter & housing"])).to eq(["food", "shelter"])
    end

    it "skips labels that belong to no category" do
      expect(described_class.keys_for(["Pet Friendly", "Meals"])).to eq(["food"])
    end

    it "returns nothing for no labels" do
      expect(described_class.keys_for(nil)).to eq([])
    end
  end

  describe ".with_keys" do
    it "returns the categories with those keys, in the order of .all" do
      expect(described_class.with_keys(["hygiene", "food"]).map(&:name)).to eq(["Food", "Hygiene & essentials"])
    end

    it "skips unknown and blank keys" do
      expect(described_class.with_keys(["", "made-up", "legal"]).map(&:key)).to eq(["legal"])
    end
  end

  it "gives every category a unique key" do
    keys = described_class.all.map(&:key)

    expect(keys).to eq(keys.uniq)
  end

  it "puts each name and label in only one category" do
    terms = described_class.all.flat_map { |category| category.terms.map(&:downcase).uniq }

    expect(terms).to eq(terms.uniq)
  end
end
