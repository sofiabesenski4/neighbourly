require "rails_helper"

# Covers turning the category names in the config into what the search needs, including
# when a category is missing from this database.
RSpec.describe Questionnaire::CategoryFilter do
  def option(key, *categories)
    Questionnaire::Option.new(key: key, label: key.capitalize, categories: categories)
  end

  let!(:meals) { Category.create!(name: "Meals") }
  let!(:food_banks) { Category.create!(name: "Food Banks") }
  let(:food) { option("food", "Meals", "Food Banks") }
  let(:legal) { option("legal", "Legal Support") }

  it "searches for every category behind the chosen options" do
    expect(described_class.new([food]).search_options[:categories])
      .to contain_exactly(meals.id.to_s, food_banks.id.to_s)
  end

  it "leaves out a category that doesn't exist" do
    food_banks.destroy!

    expect(described_class.new([food]).search_options).to eq(categories: [meals.id.to_s])
  end

  it "offers options with at least one category, and hides ones with none" do
    food_banks.destroy!

    expect(described_class.available([food, legal])).to eq([food])
  end

  it "logs the categories that are missing" do
    expect(Rails.logger).to receive(:warn).with("[Questionnaire] missing categories: Legal Support")

    described_class.available([food, legal])
  end

  it "logs nothing when none are missing" do
    expect(Rails.logger).not_to receive(:warn)

    described_class.available([food])
  end
end
