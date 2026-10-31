require "rails_helper"

RSpec.describe ResourceCategorySearch do
  let(:source) { Source.create!(name: "Local guide", source_type: "api") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
  end

  def resource(title, categories, extra = {})
    source.documents.create!(title: title, content: title, metadata: {resource_categories: categories}.merge(extra))
  end

  it "returns any selected category, grouped in the shared category order" do
    food = resource("Meals", ["food"])
    shelter = resource("Shelter", ["shelter"])
    both = resource("Both", ["food", "shelter"])
    resource("Legal", ["legal"])

    sections = described_class.call(categories: ["shelter", "food", "food", ""])

    expect(sections.map { |section| section.category.key }).to eq(["food", "shelter"])
    expect(sections[0].resources).to eq([both, food])
    expect(sections[1].resources).to eq([both, shelter])
  end

  it "includes resources without embeddings while excluding accepted removals and closed listings" do
    visible = resource("Visible", ["food"])
    missing_embedding = resource("No embedding", ["food"])
    missing_embedding.update_column(:embedding, nil)
    reported = resource("Accepted removal", ["food"])
    reported.reports.create!(reason: "out of date", status: "valid")
    resource("Closed", ["food"], closed: true)

    expect(described_class.call(categories: ["food"]).first.resources).to contain_exactly(visible, missing_embedding)
  end

  it "keeps a pending report from silently removing a resource" do
    listing = resource("Meals", ["food"])
    listing.reports.create!(reason: "unclear")

    expect(described_class.call(categories: ["food"]).first.resources).to eq([listing])
  end

  it "respects a narrower supplied scope" do
    chosen = resource("Chosen", ["food"])
    resource("Other", ["food"])

    expect(described_class.call(categories: ["food"], scope: Document.where(id: chosen.id)).first.resources).to eq([chosen])
  end

  it "returns an empty group for a valid category with no results" do
    expect(described_class.call(categories: ["legal"]).first.resources).to be_empty
  end

  it "rejects unknown categories" do
    expect { described_class.call(categories: ["food' OR 1=1 --"]) }.to raise_error(ArgumentError)
  end

  it "returns all visible resources with no filters, including uncategorized records" do
    food = resource("Meals", ["food"])
    shelter = resource("Shelter", ["shelter"])
    other = resource("Other service", [])
    unfamiliar = resource("Unmapped service", ["custom_category"])
    resource("Closed", [], closed: true)
    removed = resource("Accepted removal", [])
    removed.reports.create!(reason: "out of date", status: "valid")
    unsearchable = resource("No embedding", [])
    unsearchable.update_column(:embedding, nil)

    sections = described_class.call(categories: [])

    expect(sections.map { |section| section.category.key }).to eq(ResourceCategory.all.map(&:key) + ["uncategorized"])
    expect(sections.flat_map(&:resources)).to match_array([food, shelter, other, unfamiliar, unsearchable])
    expect(sections.last.category.name).to eq("Other resources")
    expect(sections.last.resources).to eq([unsearchable, other, unfamiliar])
  end

  it "keeps an unfiltered guide within its supplied scope" do
    chosen = resource("Chosen", [])
    resource("Other", ["food"])

    sections = described_class.call(categories: [], scope: Document.where(id: chosen.id))

    expect(sections.flat_map(&:resources)).to eq([chosen])
  end

  it "limits explicit filters to those categories and leaves uncategorized records out" do
    food = resource("Meals", ["food"])
    resource("Other", [])

    expect(described_class.call(categories: ["food"]).flat_map(&:resources)).to eq([food])
  end

  it "makes no embedding or chat call to retrieve category results" do
    listing = resource("Meals", ["food"])
    expect(ContentPipeline::Embedder).not_to receive(:embed)
    expect(RubyLLM).not_to receive(:chat)

    expect(described_class.call(categories: ["food"]).first.resources).to eq([listing])
  end

  it "does not load embedding vectors into memory for resource cards" do
    resource("Meals", ["food"])

    listing = described_class.call(categories: ["food"]).first.resources.first

    expect(listing.has_attribute?(:embedding)).to be(false)
    expect(listing.metadata["resource_categories"]).to eq(["food"])
  end
end
