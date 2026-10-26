require "rails_helper"

RSpec.describe ReportMailer, type: :mailer do
  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
  end

  let(:shelter) { source.documents.create!(title: "Test Shelter", content: "Shelter content", external_id: "1") }
  let(:food_bank) { source.documents.create!(title: "Food Bank", content: "Food content", external_id: "2") }

  describe "#daily_digest" do
    let!(:reports) do
      [
        Report.create!(document: shelter, reason: "out of date", details: "Phone number changed"),
        Report.create!(document: shelter, reason: "false information"),
        Report.create!(document: food_bank, reason: "offensive")
      ]
    end
    let(:mail) { described_class.with(admin: admin, report_ids: reports.map(&:id)).daily_digest }

    it "is sent to the admin from the no-reply address" do
      expect(mail.to).to eq(["admin@example.com"])
      expect(mail.from).to eq([Mail::Address.new(Rails.configuration.x.no_reply_email).address])
    end

    it "states the number of new reports in the subject" do
      expect(mail.subject).to eq("3 new reports to review")
    end

    it "uses the singular for a single report" do
      single = described_class.with(admin: admin, report_ids: [reports.first.id]).daily_digest
      expect(single.subject).to eq("1 new report to review")
    end

    it "groups reports by listing with their reasons" do
      [mail.html_part, mail.text_part].each do |part|
        body = part.body.to_s
        expect(body).to include("Test Shelter")
        expect(body).to include("2 reports (False information and Out of date)")
        expect(body).to include("Food Bank")
        expect(body).to include("1 report (Offensive)")
      end
    end

    it "includes the total pending backlog" do
      Report.create!(document: food_bank, reason: "unclear", digested_at: 1.day.ago)
      Report.create!(document: food_bank, reason: "unclear", status: "dismissed")

      expect(mail.text_part.body.to_s).to include("4 reports pending in total")
    end

    it "links to the moderation queue" do
      expect(mail.html_part.body.to_s).to include("http://example.com/reports")
      expect(mail.text_part.body.to_s).to include("http://example.com/reports")
    end

    it "leaves out free-text details submitted by reporters" do
      expect(mail.body.encoded).not_to include("Phone number changed")
    end
  end
end
