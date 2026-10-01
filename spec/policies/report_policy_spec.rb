require "rails_helper"

RSpec.describe ReportPolicy do
  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", admin: false) }
  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }
  let(:document) {
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    source.documents.create!(content: "test", title: "Test", external_id: "1")
  }
  let(:report) { Report.create!(document: document, user: regular_user, reason: "out of date") }

  describe "admin user" do
    subject { described_class.new(admin, report) }

    it { is_expected.to be_index }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
  end

  describe "regular user" do
    subject { described_class.new(regular_user, report) }

    it { is_expected.not_to be_index }
    it { is_expected.to be_create }
    it { is_expected.not_to be_update }
  end

  describe "guest (nil user)" do
    subject { described_class.new(nil, report) }

    it { is_expected.not_to be_index }
    it { is_expected.to be_create }
    it { is_expected.not_to be_update }
  end

  describe "Scope" do
    before { report }

    it "returns all reports for admin" do
      scope = described_class::Scope.new(admin, Report).resolve
      expect(scope).to include(report)
    end

    it "returns nothing for regular user" do
      scope = described_class::Scope.new(regular_user, Report).resolve
      expect(scope).to be_empty
    end

    it "returns nothing for guest" do
      scope = described_class::Scope.new(nil, Report).resolve
      expect(scope).to be_empty
    end
  end
end
