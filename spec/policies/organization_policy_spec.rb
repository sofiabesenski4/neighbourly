require "rails_helper"

RSpec.describe OrganizationPolicy do
  let!(:organization) { Organization.create!(name: "Our Place Society") }
  let!(:other_organization) { Organization.create!(name: "Harbour Street Society") }
  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:member) { User.create!(email: "member@example.com", password: "password123", organization: organization) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123") }

  def policy(user, record)
    described_class.new(user, record)
  end

  it "lets an admin do everything" do
    expect(policy(admin, other_organization)).to be_index.and be_show.and be_create.and be_update.and be_destroy
  end

  it "lets a member see and edit their own organization, but not add or delete one" do
    expect(policy(member, organization)).to be_index.and be_show.and be_update
    expect(policy(member, organization)).not_to be_create
    expect(policy(member, organization)).not_to be_destroy
  end

  it "keeps a member away from other organizations" do
    expect(policy(member, other_organization)).not_to be_show
    expect(policy(member, other_organization)).not_to be_update
  end

  it "gives a user with no organization, or no account, nothing" do
    [regular_user, nil].each do |user|
      expect(policy(user, organization)).not_to be_index
      expect(policy(user, organization)).not_to be_show
      expect(policy(user, organization)).not_to be_update
    end
  end

  it "scopes organizations to the member's own" do
    expect(OrganizationPolicy::Scope.new(admin, Organization).resolve).to contain_exactly(organization, other_organization)
    expect(OrganizationPolicy::Scope.new(member, Organization).resolve).to contain_exactly(organization)
    expect(OrganizationPolicy::Scope.new(regular_user, Organization).resolve).to be_empty
  end
end
