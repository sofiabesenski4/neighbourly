require "rails_helper"

RSpec.describe "Documents", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }
  let(:fake_vector) { Array.new(1536, 0.0) }
  let(:form_source) { Source.form_entry_source }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
    ["Meals", "Shelters", "Clothing"].each { |name| Category.find_or_create_by!(name: name) }
  end

  let(:document) { form_source.documents.create!(title: "Test Shelter", content: "Test Shelter\nCity: Victoria") }

  let(:valid_params) do
    {
      document: {
        title: "Harbour Street Society",
        description: "Drop-in centre offering meals and shelter",
        city: "Victoria",
        address: "100 Harbour St",
        phone: "250-555-0100",
        email: "info@example.org",
        website: "https://example.org",
        hours: "Mon-Sun 7am-11pm",
        category_ids: Category.where(name: ["Shelters", "Meals", "Clothing"]).ids,
        age_min: "19",
        age_max: "",
        gender: "all",
        notes: "No referral needed"
      }
    }
  end

  describe "GET /documents/new" do
    context "as admin" do
      before { sign_in admin }

      it "returns success" do
        get new_document_path
        expect(response).to have_http_status(:ok)
      end

      it "shows the form fields" do
        get new_document_path
        expect(response.body).to include("Resource name")
        expect(response.body).to include("Description of services")
        expect(response.body).to include("City")
        expect(response.body).to include("Hours of operation")
      end

      it "shows a checkbox for each category" do
        get new_document_path
        Category.find_each do |category|
          assert_select "input[type=checkbox][name='document[category_ids][]'][value='#{category.id}']"
        end
      end
    end

    context "as regular user" do
      before { sign_in regular_user }

      it "redirects with authorization error" do
        get new_document_path
        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "POST /documents" do
    context "as admin" do
      before { sign_in admin }

      it "creates a document with correct content" do
        expect {
          post documents_path, params: valid_params
        }.to change(Document, :count).by(1)

        doc = Document.last
        expect(doc.title).to eq("Harbour Street Society")
        expect(doc.category_names).to eq(["Clothing", "Meals", "Shelters"])
        expect(doc.content).to include("Harbour Street Society")
        expect(doc.content).to include("City: Victoria")
        expect(doc.content).to include("Address: 100 Harbour St")
        expect(doc.content).to include("Phone: 250-555-0100")
        expect(doc.content).to include("Hours: Mon-Sun 7am-11pm")
        expect(doc.content).to include("Categories: Clothing, Meals, Shelters")
        expect(doc.content).to include("Age range: 19+")
        expect(doc.content).to include("Description: Drop-in centre offering meals and shelter")
      end

      it "asks AI to fill in the new resource's service when the box is checked" do
        expect { post documents_path, params: valid_params.deep_merge(document: {enrich: "1"}) }
          .to have_enqueued_job(EnrichServiceJob)

        expect(Document.last.service).to be_awaiting_enrichment
      end

      it "leaves the service alone when the box is unchecked" do
        expect { post documents_path, params: valid_params.deep_merge(document: {enrich: "0"}) }
          .not_to have_enqueued_job(EnrichServiceJob)
      end

      # Checks the real form path end to end: submitting the form ends with a lookup
      # queued. address_spec.rb covers the rules for when a lookup is needed.
      # The resource's address and its service each hold coordinates until the
      # printout and map read services, so each gets a lookup.
      it "queues a coordinate lookup for the new resource's address and its service" do
        expect { post documents_path, params: valid_params }
          .to have_enqueued_job(GeocodeAddressJob).exactly(2).times

        document = Document.last
        expect(GeocodeAddressJob).to have_been_enqueued.with(document.address)
        expect(GeocodeAddressJob).to have_been_enqueued.with(document.service.address)
      end

      it "saves the location and phone on the address and the rest in metadata" do
        post documents_path, params: valid_params

        expect(Document.last.address).to have_attributes(
          street_address: "100 Harbour St", city: "Victoria", phone: "250-555-0100"
        )
        meta = Document.last.metadata
        expect(meta).not_to include("city", "address", "phone")
        expect(meta["email"]).to eq("info@example.org")
        expect(meta["website"]).to eq("https://example.org")
        expect(meta["hours"]).to eq("Mon-Sun 7am-11pm")
        expect(meta["age_range"]).to eq({"min" => 19})
        expect(meta["gender"]).to eq(["all"])
        expect(meta["notes"]).to eq("No referral needed")
      end

      it "associates the document with the form entry source" do
        post documents_path, params: valid_params

        doc = Document.last
        expect(doc.source.source_type).to eq("form")
        expect(doc.source.name).to eq("Form Entries")
      end

      it "generates an embedding" do
        post documents_path, params: valid_params
        expect(ContentPipeline::Embedder).to have_received(:embed)
      end

      it "redirects to sources with a notice" do
        post documents_path, params: valid_params
        expect(response).to redirect_to(sources_path)
      end

      it "renders the form again when content is blank" do
        post documents_path, params: {document: {title: "", description: ""}}
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "saves the resource's service, offered by the chosen organization" do
        organization = Organization.create!(name: "Harbourside Society")

        post documents_path, params: valid_params.deep_merge(document: {organization_id: organization.id})

        service = Document.last.service
        expect(service).to have_attributes(
          name: "Harbour Street Society", organization: organization, source: form_source,
          phone: "250-555-0100", hours: "Mon-Sun 7am-11pm",
          website: "https://example.org", description: "Drop-in centre offering meals and shelter"
        )
        expect(service.address).to have_attributes(street_address: "100 Harbour St", city: "Victoria")
        expect(service.category_names).to eq(["Clothing", "Meals", "Shelters"])
        expect(service.additional_details).to eq(
          "age_range" => {"min" => 19}, "gender" => ["all"], "notes" => "No referral needed"
        )
      end

      it "saves neither the resource nor its service when the service is invalid" do
        expect { post documents_path, params: valid_params.deep_merge(document: {title: ""}) }
          .not_to change(Document, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Name can&#39;t be blank")
        expect(Service.count).to eq(0)
      end
    end

    context "as regular user" do
      before { sign_in regular_user }

      it "denies access" do
        expect {
          post documents_path, params: valid_params
        }.not_to change(Document, :count)
      end
    end
  end

  describe "GET /documents/:id" do
    context "as admin" do
      before { sign_in admin }

      it "shows the document" do
        get document_path(document)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Test Shelter")
      end
    end

    context "as regular user" do
      before { sign_in regular_user }

      it "redirects with authorization error" do
        get document_path(document)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "GET /documents/:id/edit" do
    context "as admin" do
      before { sign_in admin }

      it "shows the edit form" do
        get edit_document_path(document)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Edit Resource")
      end
    end
  end

  describe "PATCH /documents/:id" do
    context "as admin" do
      before { sign_in admin }

      it "updates the document" do
        patch document_path(document), params: {document: {title: "Updated Name", description: "New description", city: "Nanaimo"}}

        document.reload
        expect(document.title).to eq("Updated Name")
        expect(document.content).to include("City: Nanaimo")
        expect(document.address.city).to eq("Nanaimo")
      end

      it "redirects to the show page" do
        patch document_path(document), params: valid_params
        expect(response).to redirect_to(document_path(document))
      end

      it "keeps the resource's service in step" do
        post documents_path, params: valid_params
        created = Document.last

        patch document_path(created), params: valid_params.deep_merge(document: {title: "Harbour Hub"})

        expect(created.reload.service.name).to eq("Harbour Hub")
        expect(Service.count).to eq(1)
      end

      it "shows the organization offering it on the form" do
        organization = Organization.create!(name: "Harbourside Society")
        form_source.services.create!(name: "Test Shelter", document: document, organization: organization)

        get edit_document_path(document)

        selected = Nokogiri::HTML(response.body).at_css("select#document_organization_id option[selected]")
        expect(selected.text).to eq("Harbourside Society")
      end
    end

    context "as regular user" do
      before { sign_in regular_user }

      it "denies access" do
        patch document_path(document), params: {document: {title: "Hacked"}}
        expect(document.reload.title).to eq("Test Shelter")
      end
    end
  end

  describe "DELETE /documents/:id" do
    context "as admin" do
      before { sign_in admin }

      it "deletes the document" do
        document
        expect {
          delete document_path(document)
        }.to change(Document, :count).by(-1)
      end

      it "deletes its service too" do
        form_source.services.create!(name: "Test Shelter", document: document)

        expect { delete document_path(document) }.to change(Service, :count).by(-1)
      end

      it "redirects to sources" do
        delete document_path(document)
        expect(response).to redirect_to(sources_path)
      end

      it "redirects to sources when referer is the document page" do
        document
        delete document_path(document), headers: {"HTTP_REFERER" => document_url(document)}
        expect(response).to redirect_to(sources_path)
      end

      it "redirects to sources index when referer is sources index" do
        delete document_path(document), headers: {"HTTP_REFERER" => sources_path}
        expect(response).to redirect_to(sources_path)
      end

      it "redirects to the source show page when referer is a source page" do
        source = Source.create!(name: "Test Source", source_type: "csv")
        source.documents << document
        delete document_path(document), headers: {"HTTP_REFERER" => source_url(source)}
        expect(response).to redirect_to(source_url(source))
      end

      it "redirects to sources when referer is invalid" do
        delete document_path(document), headers: {"HTTP_REFERER" => "not a valid url"}
        expect(response).to redirect_to(sources_path)
      end
    end

    context "as regular user" do
      before { sign_in regular_user }

      it "denies deletion" do
        document
        expect {
          delete document_path(document)
        }.not_to change(Document, :count)
      end
    end
  end
end
