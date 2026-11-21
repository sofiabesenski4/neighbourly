require "rails_helper"

RSpec.describe "Services", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "services-admin@example.com", password: "password123", admin: true) }
  let(:user) { User.create!(email: "services-member@example.com", password: "password123") }
  let(:organization) { Organization.create!(name: "Our Place Society") }
  let(:meals) { Category.create!(name: "Meals") }
  let(:service) { Source.form_entry_source.services.create!(name: "Community lunch", organization: organization) }

  it "is closed to regular accounts" do
    sign_in user

    get services_path
    expect(response).to redirect_to(root_path)

    post services_path, params: {service: {name: "Sneaky"}}
    expect(Service.count).to eq(0)
  end

  context "as an admin" do
    before { sign_in admin }

    it "lists services with the organization that offers each" do
      service
      Source.form_entry_source.services.create!(name: "Bike repair", address_attributes: {city: "Victoria"})

      get services_path

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.css("tbody tr td:first-child a").map(&:text)).to eq(["Bike repair", "Community lunch"])
      expect(page.css("thead th").map { |th| th.text.squish }).to include("Name ↑", "Offered by", "City", "Phone", "Categories", "Updated")
      expect(page.text.squish).to include("Our Place Society", "Victoria")
    end

    it "sorts the table by a column, either way, with blank values last" do
      service
      Source.form_entry_source.services.create!(name: "Bike repair", address_attributes: {city: "Victoria"})
      Source.form_entry_source.services.create!(name: "Arts drop-in", address_attributes: {city: "Esquimalt"})

      names = ->(params) {
        get services_path, params: params
        Nokogiri::HTML(response.body).css("tbody tr td:first-child a").map(&:text)
      }

      expect(names.call(sort: "city")).to eq(["Arts drop-in", "Bike repair", "Community lunch"])
      expect(names.call(sort: "city", direction: "desc")).to eq(["Bike repair", "Arts drop-in", "Community lunch"])
      expect(names.call(sort: "organization")).to eq(["Community lunch", "Arts drop-in", "Bike repair"])
      expect(names.call(sort: "name", direction: "desc")).to eq(["Community lunch", "Bike repair", "Arts drop-in"])
      expect(Nokogiri::HTML(response.body).at_css("th[aria-sort='descending']").text.squish).to eq("Name ↓")
      expect(names.call(sort: "id; DROP TABLE services")).to eq(["Arts drop-in", "Bike repair", "Community lunch"])
    end

    it "starts a new service linked to the organization it was opened from" do
      get new_service_path(organization_id: organization.id)

      expect(response).to have_http_status(:ok)
      selected = Nokogiri::HTML(response.body).at_css("select#service_organization_id option[selected]")
      expect(selected.text).to eq("Our Place Society")
    end

    it "creates a service as an admin entry, with its organization and categories" do
      post services_path, params: {service: {
        name: "Community lunch", organization_id: organization.id, category_ids: [meals.id],
        address_attributes: {street_address: "919 Pandora Ave", city: "Victoria", province: "BC", country: "Canada"}
      }}

      created = Service.last
      expect(response).to redirect_to(service_path(created))
      expect(created.organization).to eq(organization)
      expect(created.source).to eq(Source.form_entry_source)
      expect(created.category_names).to eq(["Meals"])
      expect(created.address).to have_attributes(street_address: "919 Pandora Ave", state: "BC", addressable: created)
    end

    it "shows the form again when the name is missing and AI won't fill it in" do
      post services_path, params: {service: {name: "", enrich: "0"}}

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Name can&#39;t be blank")
    end

    it "offers to fill in blanks with AI, checked for a new service" do
      get new_service_path

      expect(Nokogiri::HTML(response.body).at_css("input[type=checkbox][name='service[enrich]']")["checked"]).to eq("checked")
    end

    it "asks AI to fill in what a new service left blank, its name included" do
      expect { post services_path, params: {service: {name: "", description: "Free breakfasts", enrich: "1"}} }
        .to have_enqueued_job(EnrichServiceJob)

      created = Service.last
      expect(created).to have_attributes(name: nil, enrichment_requested: true)
      expect(EnrichServiceJob).to have_been_enqueued.with(created)
      follow_redirect!
      expect(response.body).to include("Unnamed service", "Waiting for AI to fill in what&#39;s blank")
    end

    it "asks AI to fill in an edited service's blanks again" do
      service.update!(enrichment_requested: true, enriched_at: 1.day.ago, enriched_description: "Old.")

      expect { patch service_path(service), params: {service: {hours: "Daily", enrich: "1"}} }
        .to have_enqueued_job(EnrichServiceJob).with(service)
      expect(service.reload).to be_awaiting_enrichment
    end

    it "queues nothing when AI isn't asked" do
      expect { patch service_path(service), params: {service: {hours: "Daily", enrich: "0"}} }
        .not_to have_enqueued_job(EnrichServiceJob)
    end

    it "shows the AI description" do
      service.update!(enriched_description: "Community lunch serves hot meals.")

      get service_path(service)

      expect(response.body).to include("AI description", "Community lunch serves hot meals.")
    end

    it "shows a service and where it came from" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      document = Source.form_entry_source.documents.create!(title: "Lunch row", content: "Lunch")
      service.update!(document: document, phone: "250-555-0100")

      get service_path(service)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Community lunch", "Our Place Society", "250-555-0100")
      expect(response.body).to include(%(href="#{document_path(document)}"))
    end

    it "confirms a service's details, saying when, how and by whom" do
      get service_path(service)
      expect(response.body).to include("Not confirmed yet")

      post confirm_service_path(service), params: {confirmation_method: "phone"}

      expect(response).to redirect_to(service_path(service))
      expect(service.reload).to have_attributes(confirmed_by: admin, confirmation_method: "phone")
      get service_path(service)
      expect(response.body).to include("by phone by services-admin@example.com")
    end

    it "doesn't confirm without knowing how the details were checked" do
      post confirm_service_path(service), params: {confirmation_method: "guess"}

      expect(flash[:alert]).to eq("Choose how you confirmed the details.")
      expect(service.reload.confirmed_at).to be_nil
    end

    it "says when a moderator removed the service's row after a report" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      document = Source.form_entry_source.documents.create!(title: "Lunch row", content: "Lunch")
      service.update!(document: document)

      get service_path(service)
      expect(response.body).not_to include("Removed by a moderator")

      document.reports.create!(reason: "out of date", status: "valid")
      get service_path(service)
      expect(response.body).to include("Removed by a moderator after a report")
    end

    it "lists details that have no field of their own" do
      service.update!(additional_details: {"languages" => ["English", "Punjabi"], "intake_steps" => {"referral" => false},
                                           "bring" => "", "referral_required" => false})

      get service_path(service)

      page = Nokogiri::HTML(response.body)
      expect(page.css("dt").map(&:text)).to include("Languages", "Intake steps", "Referral required")
      expect(page.css("dt").map(&:text)).not_to include("Bring")
      expect(page.text).to include("English, Punjabi", %("referral": false))
    end

    it "updates a service" do
      patch service_path(service), params: {service: {organization_id: "", closed: "1"}}

      expect(response).to redirect_to(service_path(service))
      expect(service.reload.organization).to be_nil
      expect(service).to be_closed
    end

    it "deletes a service" do
      delete service_path(service)

      expect(response).to redirect_to(services_path)
      expect(Service.exists?(service.id)).to be(false)
    end
  end

  context "as a member of an organization" do
    let(:member) { User.create!(email: "services-org-member@example.com", password: "password123", organization: organization) }
    let(:other_organization) { Organization.create!(name: "Harbour Street Society") }
    let(:other_service) { Source.form_entry_source.services.create!(name: "Night shelter", organization: other_organization) }

    before { sign_in member }

    it "lists only their organization's services, in the same admin pages" do
      service
      other_service

      get services_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Community lunch", "Your organization")
      expect(response.body).not_to include("Night shelter", "Sources", "Moderation")
    end

    it "adds a service to their organization, whichever organization the request names" do
      post services_path, params: {service: {name: "Breakfast club", organization_id: other_organization.id}}

      expect(Service.find_by!(name: "Breakfast club").organization).to eq(organization)
    end

    it "edits their organization's services without moving them to another organization" do
      patch service_path(service), params: {service: {phone: "250-555-0199", organization_id: other_organization.id}}

      expect(service.reload).to have_attributes(phone: "250-555-0199", organization: organization)
    end

    it "deletes their organization's services" do
      delete service_path(service)

      expect(Service.exists?(service.id)).to be(false)
    end

    it "confirms their organization's services, but not others'" do
      post confirm_service_path(service), params: {confirmation_method: "in_person"}
      expect(service.reload).to have_attributes(confirmed_by: member, confirmation_method: "in_person")

      post confirm_service_path(other_service), params: {confirmation_method: "in_person"}
      expect(other_service.reload.confirmed_at).to be_nil
    end

    it "keeps them away from other organizations' services" do
      get service_path(other_service)
      expect(response).to redirect_to(root_path)

      patch service_path(other_service), params: {service: {name: "Taken"}}
      expect(other_service.reload.name).to eq("Night shelter")

      delete service_path(other_service)
      expect(Service.exists?(other_service.id)).to be(true)
    end

    it "names where an imported service came from without linking to admin-only pages" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      source = Source.create!(name: "Victoria directory", source_type: "csv")
      row = source.documents.create!(title: "Lunch row", content: "Lunch")
      imported = source.services.create!(name: "Imported lunch", organization: organization, document: row)

      get service_path(imported)

      expect(response.body).to include("Lunch row", "Victoria directory")
      expect(response.body).not_to include(document_path(row), source_path(source))
    end

    it "closes an imported service rather than deleting it" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      source = Source.create!(name: "Victoria directory", source_type: "csv")
      imported = source.services.create!(name: "Imported lunch", organization: organization,
        document: source.documents.create!(title: "Lunch row", content: "Lunch"))

      get service_path(imported)
      expect(response.body).to include("can't be deleted here").and include("mark it closed")
      expect(Nokogiri::HTML(response.body).css("button").map(&:text)).not_to include("Delete")

      delete service_path(imported)
      expect(Service.exists?(imported.id)).to be(true)

      patch service_path(imported), params: {service: {closed: "1"}}
      expect(imported.reload).to be_closed
    end
  end
end
