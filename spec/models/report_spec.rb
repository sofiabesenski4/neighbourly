require "rails_helper"

RSpec.describe Report, type: :model do
  let(:user) { User.create!(email: "user@example.com", password: "password123") }
  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }
  let(:document) {
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    source.documents.create!(content: "test content", title: "Test Doc", external_id: "1")
  }

  def build_report(**overrides)
    Report.new({document: document, user: user, reason: "out of date"}.merge(overrides))
  end

  describe "validations" do
    it "is valid with required attributes" do
      expect(build_report).to be_valid
    end

    it "requires a reason" do
      expect(build_report(reason: nil)).not_to be_valid
    end

    it "requires reason to be in the allowed list" do
      Report::REASONS.each do |reason|
        expect(build_report(reason: reason)).to be_valid
      end
      expect(build_report(reason: "spam")).not_to be_valid
    end

    it "requires a status in the allowed list" do
      Report::STATUSES.each do |status|
        expect(build_report(status: status)).to be_valid
      end
      expect(build_report(status: "archived")).not_to be_valid
    end

    it "defaults status to pending" do
      report = Report.new
      expect(report.status).to eq("pending")
    end
  end

  describe "associations" do
    it "belongs to a document" do
      report = build_report
      report.save!
      expect(report.document).to eq(document)
    end

    it "optionally belongs to a user" do
      report = build_report
      report.save!
      expect(report.user).to eq(user)
    end

    it "is valid without a user" do
      report = build_report(user: nil)
      expect(report).to be_valid
    end

    it "is destroyed when its document is destroyed" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      report = build_report
      report.save!
      expect { document.destroy! }.to change(Report, :count).by(-1)
    end

    it "is destroyed when its user is destroyed" do
      report = build_report
      report.save!
      expect { user.destroy! }.to change(Report, :count).by(-1)
    end
  end

  describe "scopes" do
    before do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    end

    it ".pending returns only pending reports" do
      pending_report = Report.create!(document: document, user: user, reason: "out of date")
      dismissed_report = Report.create!(document: document, user: user, reason: "offensive", status: "dismissed")

      expect(Report.pending).to include(pending_report)
      expect(Report.pending).not_to include(dismissed_report)
    end

    it ".most_recent orders by created_at descending" do
      old_report = Report.create!(document: document, user: user, reason: "out of date")
      new_report = Report.create!(document: document, user: user, reason: "offensive")

      expect(Report.most_recent.first).to eq(new_report)
      expect(Report.most_recent.last).to eq(old_report)
    end
  end

  describe "status predicates" do
    it "#pending? returns true for pending status" do
      report = build_report(status: "pending")
      expect(report.pending?).to be true
      expect(report.valid_report?).to be false
      expect(report.dismissed?).to be false
    end

    it "#valid_report? returns true for valid status" do
      report = build_report(status: "valid")
      expect(report.valid_report?).to be true
      expect(report.pending?).to be false
    end

    it "#dismissed? returns true for dismissed status" do
      report = build_report(status: "dismissed")
      expect(report.dismissed?).to be true
      expect(report.pending?).to be false
    end
  end
end
