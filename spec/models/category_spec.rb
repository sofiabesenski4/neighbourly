require "rails_helper"

RSpec.describe Category do
  it "rejects a parent that would create a cycle" do
    parent = described_class.create!(name: "Food")
    child = described_class.create!(name: "Meals", parent: parent)

    parent.parent = child
    expect(parent).not_to be_valid
    expect(parent.errors[:parent]).to include("cannot create a category cycle")
  end

  it "keeps subcategories when their parent is removed" do
    parent = described_class.create!(name: "Food")
    child = described_class.create!(name: "Meals", parent: parent)

    parent.destroy!

    expect(child.reload.parent_id).to be_nil
  end
end
