require "rails_helper"

RSpec.describe "Reports", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }
  let(:fake_vector) { Array.new(1536, 0.0) }
  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
  end

  let(:document) { source.documents.create!(title: "Test Shelter", content: "Test content", external_id: "1") }
  let(:report) { Report.create!(document: document, user: regular_user, reason: "out of date", details: "Phone number changed") }

  describe "GET /reports" do
    context "as admin" do
      before { sign_in admin }

      it "returns success" do
        get reports_path
        expect(response).to have_http_status(:ok)
      end

      it "shows existing reports" do
        report
        get reports_path
        expect(response.body).to include("Test Shelter")
        expect(response.body).to include("user@example.com")
        expect(response.body).to include("Out of date")
        expect(response.body).to include("Phone number changed")
      end

      it "shows an empty state when no reports exist" do
        get reports_path
        expect(response.body).to include("No reports have been submitted")
      end
    end

    context "as regular user" do
      before { sign_in regular_user }

      it "redirects with authorization error" do
        get reports_path
        expect(response).to redirect_to(root_path)
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        get reports_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "POST /reports" do
    let(:valid_params) do
      {report: {document_id: document.id, reason: "false information", details: "This is incorrect"}}
    end

    context "as signed-in user" do
      before { sign_in regular_user }

      it "creates a report" do
        expect {
          post reports_path, params: valid_params
        }.to change(Report, :count).by(1)
      end

      it "sets the correct attributes" do
        post reports_path, params: valid_params

        report = Report.last
        expect(report.document).to eq(document)
        expect(report.user).to eq(regular_user)
        expect(report.reason).to eq("false information")
        expect(report.details).to eq("This is incorrect")
        expect(report.status).to eq("pending")
      end

      it "redirects with a success notice" do
        post reports_path, params: valid_params
        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(response.body).to include("Your report has been submitted")
      end

      it "handles invalid params gracefully" do
        post reports_path, params: {report: {document_id: document.id, reason: "invalid_reason"}}
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("Could not submit report")
      end
    end

    context "when not signed in" do
      it "creates an anonymous report" do
        expect {
          post reports_path, params: valid_params
        }.to change(Report, :count).by(1)

        report = Report.last
        expect(report.user).to be_nil
        expect(report.reason).to eq("false information")
      end
    end
  end

  describe "PATCH /reports/:id/dismiss" do
    context "as admin" do
      before { sign_in admin }

      it "sets the report status to dismissed" do
        patch dismiss_report_path(report)
        expect(report.reload.status).to eq("dismissed")
      end

      it "redirects to reports index with a notice" do
        patch dismiss_report_path(report)
        expect(response).to redirect_to(reports_path)
        follow_redirect!
        expect(response.body).to include("Report dismissed")
      end
    end

    context "as regular user" do
      before { sign_in regular_user }

      it "denies access" do
        patch dismiss_report_path(report)
        expect(report.reload.status).to eq("pending")
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        patch dismiss_report_path(report)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "PATCH /reports/:id/validate" do
    context "as admin" do
      before { sign_in admin }

      it "sets the report status to valid" do
        patch validate_report_path(report)
        expect(report.reload.status).to eq("valid")
      end

      it "nulls out the document embedding" do
        expect(document.embedding).not_to be_nil

        patch validate_report_path(report)
        expect(document.reload.embedding).to be_nil
      end

      it "marks all pending reports for the same document as valid" do
        other_report = Report.create!(document: document, user: admin, reason: "offensive")

        patch validate_report_path(report)

        expect(report.reload.status).to eq("valid")
        expect(other_report.reload.status).to eq("valid")
      end

      it "does not change already-dismissed reports for the same document" do
        dismissed_report = Report.create!(document: document, user: admin, reason: "unclear", status: "dismissed")

        patch validate_report_path(report)

        expect(dismissed_report.reload.status).to eq("dismissed")
      end

      it "preserves the document record" do
        patch validate_report_path(report)
        expect(Document.exists?(document.id)).to be true
      end

      it "redirects to reports index with a notice" do
        patch validate_report_path(report)
        expect(response).to redirect_to(reports_path)
        follow_redirect!
        expect(response.body).to include("removed from search results")
      end
    end

    context "as regular user" do
      before { sign_in regular_user }

      it "denies access" do
        patch validate_report_path(report)
        expect(report.reload.status).to eq("pending")
        expect(document.reload.embedding).not_to be_nil
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        patch validate_report_path(report)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end
end
