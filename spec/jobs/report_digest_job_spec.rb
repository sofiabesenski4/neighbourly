require "rails_helper"

RSpec.describe ReportDigestJob, type: :job do
  include ActiveJob::TestHelper

  let!(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let!(:other_admin) { User.create!(email: "other-admin@example.com", password: "password123", admin: true) }
  let!(:regular_user) { User.create!(email: "user@example.com", password: "password123") }
  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
  end

  let(:document) { source.documents.create!(title: "Test Shelter", content: "Test content", external_id: "1") }

  def deliveries
    perform_enqueued_jobs { described_class.perform_now }
    ActionMailer::Base.deliveries
  end

  after { ActionMailer::Base.deliveries.clear }

  it "sends nothing when there are no new reports" do
    expect(deliveries).to be_empty
  end

  context "with new pending reports" do
    let!(:report) { Report.create!(document: document, reason: "out of date") }

    it "emails each admin once" do
      expect(deliveries.flat_map(&:to)).to contain_exactly("admin@example.com", "other-admin@example.com")
    end

    it "marks the reports as digested" do
      freeze_time do
        deliveries
        expect(report.reload.digested_at).to eq(Time.current)
      end
    end

    it "does not send the same reports twice" do
      deliveries
      ActionMailer::Base.deliveries.clear

      expect(deliveries).to be_empty
    end
  end

  it "skips reports already resolved by a moderator" do
    Report.create!(document: document, reason: "out of date", status: "dismissed")

    expect(deliveries).to be_empty
  end

  it "keeps reports undigested while there are no admins" do
    User.where(admin: true).delete_all
    report = Report.create!(document: document, reason: "out of date")

    expect(deliveries).to be_empty
    expect(report.reload.digested_at).to be_nil
  end
end
