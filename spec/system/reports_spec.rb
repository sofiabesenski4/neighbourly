require "rails_helper"

RSpec.describe "Reports", type: :system do
  before do
    driven_by(:rack_test)
  end

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", admin: false) }
  let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }
  let(:source) { Source.create!(name: "Test API", url: "https://example.com", source_type: "api") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
  end

  let(:document) { source.documents.create!(title: "Test Shelter", content: "Test content", external_id: "1") }

  describe "authorization" do
    it "prevents non-admin users from accessing reports index" do
      login_as(regular_user, scope: :user)
      visit reports_path

      expect(page).to have_content("You are not authorized to perform this action.")
    end

    it "redirects guests to sign in" do
      visit reports_path

      expect(page).to have_content("Sign in to your account")
    end
  end

  context "as an admin" do
    before { login_as(admin, scope: :user) }

    it "shows the Reports link in the nav" do
      visit root_path
      expect(page).to have_link("Moderation", href: reports_path)
    end

    it "shows an empty state when no reports exist" do
      visit reports_path
      expect(page).to have_content("No reports have been submitted.")
    end

    it "lists reports with document, reporter, reason, and status" do
      Report.create!(document: document, user: regular_user, reason: "out of date", details: "Phone number changed")

      visit reports_path

      expect(page).to have_content("Test Shelter")
      expect(page).to have_content("user@example.com")
      expect(page).to have_content("Out of date")
      expect(page).to have_content("Phone number changed")
      expect(page).to have_content("Pending")
    end

    it "shows the source name linked to the source" do
      Report.create!(document: document, user: regular_user, reason: "out of date")

      visit reports_path

      expect(page).to have_link("Test API", href: source_path(source))
    end

    it "shows the flagged document content" do
      Report.create!(document: document, user: regular_user, reason: "out of date")

      visit reports_path

      expect(page).to have_content("Flagged content")
      expect(page).to have_content("Test content")
    end

    describe "dismissing a report" do
      it "changes the status to dismissed" do
        report = Report.create!(document: document, user: regular_user, reason: "unclear")

        visit reports_path
        click_button "Dismiss"

        expect(page).to have_content("Report dismissed")
        expect(report.reload.status).to eq("dismissed")
      end

      it "hides action buttons after dismissal" do
        Report.create!(document: document, user: regular_user, reason: "unclear")

        visit reports_path
        click_button "Dismiss"

        expect(page).to have_content("Dismissed")
        expect(page).not_to have_button("Dismiss")
      end
    end

    describe "validating a report" do
      it "marks the report as valid and removes the document from search" do
        report = Report.create!(document: document, user: regular_user, reason: "false information")

        visit reports_path
        click_button "Accept removal"

        expect(page).to have_content("removed from search results")
        expect(report.reload.status).to eq("valid")
        expect(document.reload.embedding).to be_nil
      end

      it "marks all pending reports for the same document as valid" do
        report1 = Report.create!(document: document, user: regular_user, reason: "false information")
        report2 = Report.create!(document: document, user: admin, reason: "out of date")

        visit reports_path
        first("button", text: "Accept removal").click

        expect(report1.reload.status).to eq("valid")
        expect(report2.reload.status).to eq("valid")
      end

      it "preserves the document record" do
        Report.create!(document: document, user: regular_user, reason: "offensive")

        visit reports_path
        click_button "Accept removal"

        expect(Document.exists?(document.id)).to be true
      end
    end
  end

  context "as a regular user" do
    before { login_as(regular_user, scope: :user) }

    it "does not show the Reports link in the nav" do
      visit root_path
      expect(page).not_to have_link("Moderation", href: reports_path)
    end
  end
end
