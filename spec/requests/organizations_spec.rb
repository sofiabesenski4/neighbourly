require "rails_helper"

RSpec.describe "Organizations", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "organizations-admin@example.com", password: "password123", admin: true) }
  let(:user) { User.create!(email: "organizations-member@example.com", password: "password123") }
  let(:organization) { Organization.create!(name: "Our Place Society", phone: "250-555-0100") }

  it "is closed to regular accounts" do
    sign_in user

    get organizations_path
    expect(response).to redirect_to(root_path)

    post organizations_path, params: {organization: {name: "Sneaky"}}
    expect(Organization.count).to eq(0)
  end

  context "as an admin" do
    before { sign_in admin }

    it "lists organizations with how many services each offers" do
      Source.form_entry_source.services.create!(name: "Community lunch", organization: organization)
      Organization.create!(name: "Harbour Street Society")

      get organizations_path

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.css("article a.admin-link").map(&:text)).to eq(["Harbour Street Society", "Our Place Society"])
      expect(page.text.squish).to include("0 services", "1 service")
    end

    it "shows an organization and the services it offers" do
      Source.form_entry_source.services.create!(name: "Community lunch", organization: organization)

      get organization_path(organization)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Our Place Society", "250-555-0100", "Community lunch")
      expect(response.body).to include(%(href="#{new_service_path(organization_id: organization.id)}"))
    end

    it "creates an organization" do
      post organizations_path, params: {organization: {name: "Harbour Street Society", website: "https://example.org"}}

      created = Organization.last
      expect(response).to redirect_to(organization_path(created))
      expect(created.website).to eq("https://example.org")
    end

    it "shows the form again when the name is already used" do
      organization

      post organizations_path, params: {organization: {name: "our place society"}}

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Name is already used by another organization")
    end

    it "saves the organization's address and shows it" do
      patch organization_path(organization), params: {organization: {address_attributes: {street_address: "919 Pandora Ave", city: "Victoria"}}}

      expect(organization.reload.address.street_address).to eq("919 Pandora Ave")
      get organization_path(organization)
      expect(response.body).to include("919 Pandora Ave, Victoria")
    end

    it "updates an organization" do
      patch organization_path(organization), params: {organization: {email: "hello@example.org"}}

      expect(response).to redirect_to(organization_path(organization))
      expect(organization.reload.email).to eq("hello@example.org")
    end

    it "deletes an organization and keeps its services" do
      service = Source.form_entry_source.services.create!(name: "Community lunch", organization: organization)

      delete organization_path(organization)

      expect(response).to redirect_to(organizations_path)
      expect(Organization.exists?(organization.id)).to be(false)
      expect(service.reload.organization).to be_nil
    end
  end

  context "as a member of an organization" do
    let(:member) { User.create!(email: "organizations-org-member@example.com", password: "password123", organization: organization) }
    let(:other_organization) { Organization.create!(name: "Harbour Street Society") }

    before { sign_in member }

    it "shows and edits their own organization" do
      get organization_path(organization)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(">Delete<")

      patch organization_path(organization), params: {organization: {phone: "250-555-0199"}}
      expect(organization.reload.phone).to eq("250-555-0199")
    end

    it "lists only their own organization" do
      other_organization

      get organizations_path

      expect(response.body).to include("Our Place Society")
      expect(response.body).not_to include("Harbour Street Society", "Add organization")
    end

    it "keeps them away from other organizations, and from adding or deleting any" do
      get organization_path(other_organization)
      expect(response).to redirect_to(root_path)

      post organizations_path, params: {organization: {name: "Sneaky"}}
      expect(Organization.find_by(name: "Sneaky")).to be_nil

      delete organization_path(organization)
      expect(Organization.exists?(organization.id)).to be(true)
    end
  end
end
