require "rails_helper"

RSpec.describe Organization, type: :model do
  let(:source) { Source.create!(name: "Directory", source_type: "csv") }

  it "needs a name" do
    organization = Organization.new(name: "  ")

    expect(organization).not_to be_valid
    expect(organization.errors[:name]).to include("can't be blank")
  end

  it "treats names that differ only in case and spacing as the same organization" do
    Organization.create!(name: "Our Place Society")
    duplicate = Organization.new(name: "  our  place SOCIETY ")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:name]).to include("is already used by another organization")
  end

  it "keeps the name as written, with spacing tidied" do
    organization = Organization.create!(name: "  Our  Place Society ")

    expect(organization.name).to eq("Our Place Society")
    expect(organization.normalized_name).to eq("our place society")
  end

  it "can be saved again under its own name" do
    organization = Organization.create!(name: "Our Place Society")

    expect(organization.update(phone: "250-555-0100")).to be(true)
  end

  it "only accepts web addresses" do
    organization = Organization.new(name: "Our Place Society", website: "javascript:alert(1)")

    expect(organization).not_to be_valid
    expect(organization.errors[:website]).to include("must start with http:// or https://")
  end

  it "keeps its services, unlinked, when it is deleted" do
    organization = Organization.create!(name: "Our Place Society")
    service = source.services.create!(name: "Community lunch", organization: organization)

    organization.destroy!

    expect(service.reload.organization).to be_nil
  end
end
