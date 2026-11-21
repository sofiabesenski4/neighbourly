require "rails_helper"

RSpec.describe CategorySearch do
  let(:source) { Source.create!(name: "Local guide", source_type: "csv") }
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:shelters) { Category.create!(name: "Shelters") }
  let!(:showers) { Category.create!(name: "Showers") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
  end

  def resource(name, categories, **attributes)
    source.services.create!(name: name, categories: categories, **attributes)
  end

  # A moderator accepted a report on the row the service was read from.
  def removed(name, categories)
    row = source.documents.create!(title: name, content: name)
    row.reports.create!(reason: "out of date", status: "valid")
    resource(name, categories, document: row)
  end

  it "returns any selected category in name order, repeating shared resources in each section" do
    meal = resource("Meal program", [meals])
    shelter = resource("Shelter", [shelters])
    both = resource("Both", [meals, shelters])
    resource("Showers", [showers])

    sections = described_class.call(categories: [shelters.id.to_s, meals.id.to_s, meals.id.to_s, ""])

    expect(sections.map(&:category)).to eq([meals, shelters])
    expect(sections.map(&:resources)).to eq([[both, meal], [both, shelter]])
  end

  it "uses new and renamed categories without an application mapping" do
    category = Category.create!(name: "Computer access")
    listing = resource("Library", [category])
    category.update!(name: "Internet access")

    section = described_class.call(categories: [category.id.to_s]).first

    expect(section.name).to eq("Internet access")
    expect(section.resources).to eq([listing])
  end

  it "includes descendants of a selected category and narrows to a selected child" do
    food = Category.create!(name: "Food")
    groceries = Category.create!(name: "Groceries", parent: food)
    pantry = Category.create!(name: "Pantry", parent: groceries)
    meals.update!(parent: food)
    meal_program = resource("Meal program", [meals])
    pantry_program = resource("Pantry program", [pantry])
    resource("Shelter", [shelters])

    parent_sections = described_class.call(categories: [food.id.to_s, groceries.id.to_s])
    child_sections = described_class.call(categories: [groceries.id.to_s])

    expect(parent_sections.flat_map(&:resources)).to match_array([meal_program, pantry_program])
    expect(child_sections.flat_map(&:resources)).to eq([pantry_program])
  end

  it "matches searchable card fields and sorts resources once across categories" do
    alpha = resource("Alpha pantry", [meals, shelters], description: "Hot meals")
    zebra = resource("Zebra program", [shelters], description: "Hot meals")
    resource("Other meal program", [meals], description: "Hot meals")
    resource("Unrelated", [shelters], description: "Cold drinks")

    sections = described_class.call(categories: [shelters.id.to_s], query: " HOT MEALS ", sort: "desc")

    expect(sections.map(&:name)).to eq(["Resources"])
    expect(sections.first.resources).to eq([zebra, alpha])
  end

  it "excludes accepted removals and closed services" do
    visible = resource("Visible", [meals])
    removed("Accepted removal", [meals])
    resource("Closed", [meals], closed: true)

    expect(described_class.call(categories: [meals.id.to_s]).first.resources).to eq([visible])
  end

  it "keeps pending reports visible" do
    row = source.documents.create!(title: "Meals", content: "Meals")
    row.reports.create!(reason: "unclear")
    listing = resource("Meals", [meals], document: row)

    expect(described_class.call(categories: [meals.id.to_s]).first.resources).to eq([listing])
  end

  it "returns an empty section for an existing category with no results" do
    expect(described_class.call(categories: [showers.id.to_s]).first.resources).to be_empty
  end

  it "rejects unknown IDs rather than broadening a mixed selection" do
    expect { described_class.call(categories: [meals.id.to_s, "0"]) }.to raise_error(ArgumentError)
    expect { described_class.call(categories: ["1 OR 1=1"]) }.to raise_error(ArgumentError)
  end

  it "returns all visible resources with no filters, including uncategorized records" do
    meal = resource("Meals", [meals])
    shelter = resource("Shelter", [shelters])
    other = resource("Other service", [])
    resource("Closed", [], closed: true)
    removed("Accepted removal", [])
    another = resource("Another service", [])

    sections = described_class.call(categories: [])

    expect(sections.map(&:category)).to eq([meals, shelters, showers, nil])
    expect(sections.flat_map(&:resources)).to match_array([meal, shelter, other, another])
    expect(sections.last.name).to eq("Other resources")
    expect(sections.last.resources).to eq([another, other])
  end

  it "shows uncategorized resources when no database categories exist" do
    Category.delete_all
    listing = resource("Noticeboard", [])

    sections = described_class.call(categories: [])

    expect(sections.map(&:name)).to eq(["Other resources"])
    expect(sections.first.resources).to eq([listing])
  end

  it "leaves uncategorized resources out of an explicit selection" do
    meal = resource("Meals", [meals])
    resource("Other", [])

    expect(described_class.call(categories: [meals.id.to_s]).flat_map(&:resources)).to eq([meal])
  end

  it "makes no embedding or chat call to retrieve category results" do
    listing = resource("Meals", [meals])
    expect(ContentPipeline::Embedder).not_to receive(:embed)
    expect(RubyLLM).not_to receive(:chat)

    expect(described_class.call(categories: [meals.id.to_s]).first.resources).to eq([listing])
  end
end
