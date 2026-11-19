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
      Source.form_entry_source.services.create!(name: "Bike repair", city: "Victoria")

      get services_path

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.css("article a.admin-link").map(&:text)).to eq(["Bike repair", "Community lunch"])
      expect(page.text.squish).to include("Our Place Society", "Victoria")
    end

    it "starts a new service linked to the organization it was opened from" do
      get new_service_path(organization_id: organization.id)

      expect(response).to have_http_status(:ok)
      selected = Nokogiri::HTML(response.body).at_css("select#service_organization_id option[selected]")
      expect(selected.text).to eq("Our Place Society")
    end

    it "creates a service as an admin entry, with its organization and categories" do
      post services_path, params: {service: {
        name: "Community lunch", organization_id: organization.id, address_line: "919 Pandora Ave",
        city: "Victoria", province: "BC", country: "Canada", category_ids: [meals.id]
      }}

      created = Service.last
      expect(response).to redirect_to(service_path(created))
      expect(created.organization).to eq(organization)
      expect(created.source).to eq(Source.form_entry_source)
      expect(created.category_names).to eq(["Meals"])
      expect(created.state).to eq("BC")
    end

    it "shows the form again when the name is missing" do
      post services_path, params: {service: {name: ""}}

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Name can&#39;t be blank")
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

    it "lists details that have no field of their own" do
      service.update!(additional_details: {"languages" => ["English", "Punjabi"], "intake_steps" => {"referral" => false}, "bring" => ""})

      get service_path(service)

      page = Nokogiri::HTML(response.body)
      expect(page.css("dt").map(&:text)).to include("Languages", "Intake steps")
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
end
