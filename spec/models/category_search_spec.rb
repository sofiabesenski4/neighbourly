require "rails_helper"

RSpec.describe CategorySearch do
  let(:source) { Source.create!(name: "Local guide", source_type: "api") }
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:shelters) { Category.create!(name: "Shelters") }
  let!(:showers) { Category.create!(name: "Showers") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
  end

  def resource(title, categories, metadata = {})
    source.documents.create!(title: title, content: title, categories: categories, metadata: metadata)
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

  it "uses associations exclusively, ignoring stale category metadata" do
    listing = resource("Shelter", [shelters], categories: ["Meals"], resource_categories: ["food"])
    metadata_only = resource("Metadata only", [], categories: ["Meals"], resource_categories: ["food"])

    expect(described_class.call(categories: [meals.id.to_s]).first.resources).to be_empty
    expect(described_class.call(categories: [shelters.id.to_s]).first.resources).to eq([listing])
    expect(described_class.call(categories: []).last.resources).to eq([metadata_only])
  end

  it "includes resources without embeddings while excluding accepted removals and closed listings" do
    visible = resource("Visible", [meals])
    missing_embedding = resource("No embedding", [meals])
    missing_embedding.update_column(:embedding, nil)
    reported = resource("Accepted removal", [meals])
    reported.reports.create!(reason: "out of date", status: "valid")
    resource("Closed", [meals], closed: true)

    expect(described_class.call(categories: [meals.id.to_s]).first.resources).to contain_exactly(visible, missing_embedding)
  end

  it "keeps pending reports visible" do
    listing = resource("Meals", [meals])
    listing.reports.create!(reason: "unclear")

    expect(described_class.call(categories: [meals.id.to_s]).first.resources).to eq([listing])
  end

  it "respects a narrower supplied scope" do
    chosen = resource("Chosen", [meals])
    resource("Other", [meals])

    expect(described_class.call(categories: [meals.id.to_s], scope: Document.where(id: chosen.id)).first.resources).to eq([chosen])
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
    removed = resource("Accepted removal", [])
    removed.reports.create!(reason: "out of date", status: "valid")
    unsearchable = resource("No embedding", [])
    unsearchable.update_column(:embedding, nil)

    sections = described_class.call(categories: [])

    expect(sections.map(&:category)).to eq([meals, shelters, showers, nil])
    expect(sections.flat_map(&:resources)).to match_array([meal, shelter, other, unsearchable])
    expect(sections.last.name).to eq("Other resources")
    expect(sections.last.resources).to eq([unsearchable, other])
  end

  it "shows uncategorized resources when no database categories exist" do
    Category.delete_all
    listing = resource("Noticeboard", [])

    sections = described_class.call(categories: [])

    expect(sections.map(&:name)).to eq(["Other resources"])
    expect(sections.first.resources).to eq([listing])
  end

  it "keeps an unfiltered guide within its supplied scope" do
    chosen = resource("Chosen", [])
    resource("Other", [meals])

    sections = described_class.call(categories: [], scope: Document.where(id: chosen.id))

    expect(sections.flat_map(&:resources)).to eq([chosen])
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

  it "does not load embedding vectors into memory for resource cards" do
    resource("Meals", [meals])

    listing = described_class.call(categories: [meals.id.to_s]).first.resources.first

    expect(listing.has_attribute?(:embedding)).to be(false)
    expect(listing.categories).to eq([meals])
  end
end
