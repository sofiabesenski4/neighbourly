require "rails_helper"

RSpec.describe ServicePolicy do
  let(:organization) { Organization.create!(name: "Our Place Society") }
  let(:other_organization) { Organization.create!(name: "Harbour Street Society") }
  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:member) { User.create!(email: "member@example.com", password: "password123", organization: organization) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123") }
  let!(:own_service) { Source.form_entry_source.services.create!(name: "Community lunch", organization: organization) }
  let!(:other_service) { Source.form_entry_source.services.create!(name: "Night shelter", organization: other_organization) }
  let!(:unlinked_service) { Source.form_entry_source.services.create!(name: "Bike repair") }

  def policy(user, record)
    described_class.new(user, record)
  end

  it "lets an admin do everything" do
    expect(policy(admin, other_service)).to be_index.and be_show.and be_create.and be_update.and be_destroy
  end

  it "lets a member manage their organization's services" do
    expect(policy(member, own_service)).to be_index.and be_show.and be_create.and be_update.and be_destroy
  end

  # It would come back with the next import, and its row would stay in chat.
  it "lets nobody delete an imported service, though it can be edited and closed" do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    source = Source.create!(name: "Directory", source_type: "csv")
    imported = source.services.create!(name: "Imported lunch", organization: organization,
      document: source.documents.create!(title: "Lunch row", content: "Lunch"))

    [admin, member].each do |user|
      expect(policy(user, imported)).to be_update
      expect(policy(user, imported)).not_to be_destroy
    end
  end

  it "keeps a member away from other services" do
    [other_service, unlinked_service].each do |service|
      expect(policy(member, service)).not_to be_show
      expect(policy(member, service)).not_to be_update
      expect(policy(member, service)).not_to be_destroy
    end
  end

  it "gives a user with no organization, or no account, nothing" do
    [regular_user, nil].each do |user|
      expect(policy(user, own_service)).not_to be_index
      expect(policy(user, own_service)).not_to be_show
      expect(policy(user, own_service)).not_to be_create
    end
  end

  it "scopes services to the member's organization" do
    expect(ServicePolicy::Scope.new(admin, Service).resolve).to contain_exactly(own_service, other_service, unlinked_service)
    expect(ServicePolicy::Scope.new(member, Service).resolve).to contain_exactly(own_service)
    expect(ServicePolicy::Scope.new(regular_user, Service).resolve).to be_empty
  end
end
