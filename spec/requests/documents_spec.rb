require "rails_helper"

RSpec.describe "Documents", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }
  let(:fake_vector) { Array.new(1536, 0.0) }
  let(:form_source) { Source.form_entry_source }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
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
        categories: "shelter, meals, clothing",
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
        expect(doc.content).to include("Harbour Street Society")
        expect(doc.content).to include("City: Victoria")
        expect(doc.content).to include("Address: 100 Harbour St")
        expect(doc.content).to include("Phone: 250-555-0100")
        expect(doc.content).to include("Hours: Mon-Sun 7am-11pm")
        expect(doc.content).to include("Categories: shelter, meals, clothing")
        expect(doc.content).to include("Age range: 19+")
        expect(doc.content).to include("Description: Drop-in centre offering meals and shelter")
      end

      it "creates a document with correct metadata" do
        post documents_path, params: valid_params

        meta = Document.last.metadata
        expect(meta["city"]).to eq("Victoria")
        expect(meta["address"]).to eq("100 Harbour St")
        expect(meta["phone"]).to eq(["250-555-0100"])
        expect(meta["email"]).to eq("info@example.org")
        expect(meta["website"]).to eq("https://example.org")
        expect(meta["hours"]).to eq("Mon-Sun 7am-11pm")
        expect(meta["categories"]).to eq(["shelter", "meals", "clothing"])
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
        expect(document.metadata["city"]).to eq("Nanaimo")
      end

      it "redirects to the show page" do
        patch document_path(document), params: valid_params
        expect(response).to redirect_to(document_path(document))
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

      it "redirects to sources" do
        delete document_path(document)
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
