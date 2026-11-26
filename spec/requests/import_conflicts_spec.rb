require "rails_helper"

RSpec.describe "Import review", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "import-admin@example.com", password: "password123", admin: true) }
  let(:user) { User.create!(email: "import-member@example.com", password: "password123") }
  let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv") }
  let(:service) { source.services.create!(name: "Harbour Meals", phone: "250-555-0101", hours: "Weekdays") }
  let!(:phone) { service.import_conflicts.create!(field: "phone", incoming_value: "250-555-0199") }
  let!(:hours) { service.import_conflicts.create!(field: "hours", incoming_value: nil) }

  it "is closed to regular accounts" do
    sign_in user

    get import_conflicts_path
    expect(response).to redirect_to(root_path)

    patch approve_import_conflict_path(phone)
    expect(service.reload.phone).to eq("250-555-0101")
  end

  context "as an admin" do
    before { sign_in admin }

    it "lists each waiting detail with its current and incoming values" do
      get import_conflicts_path

      rows = Nokogiri::HTML(response.body).css("tbody tr").map { |row| row.css("th, td").first(3).map { |cell| cell.text.squish } }
      expect(rows).to eq([["Hours", "Weekdays", "Blank"], ["Phone", "250-555-0101", "250-555-0199"]])
    end

    it "shows an empty state when nothing waits" do
      ImportConflict.delete_all

      get import_conflicts_path

      expect(response.body).to include("No imported changes are waiting for review")
    end

    it "uses the import's value for one detail" do
      patch approve_import_conflict_path(phone)

      expect(response).to redirect_to(import_conflicts_path)
      expect(service.reload).to have_attributes(phone: "250-555-0199", hours: "Weekdays")
      expect(hours.reload.status).to eq("pending")
    end

    it "keeps the current value for one detail" do
      patch reject_import_conflict_path(hours)

      expect(service.reload.hours).to eq("Weekdays")
      expect(hours.reload).to have_attributes(status: "rejected", decided_by: admin)
    end

    it "uses every value the import gives a service at once" do
      patch approve_all_import_conflicts_path(service_id: service.id)

      expect(service.reload).to have_attributes(phone: "250-555-0199", hours: nil)
      expect(service.import_conflicts.pending).to be_empty
    end

    it "keeps every current value of a service at once" do
      patch reject_all_import_conflicts_path(service_id: service.id)

      expect(service.reload).to have_attributes(phone: "250-555-0101", hours: "Weekdays")
      expect(service.import_conflicts.pluck(:status)).to all(eq("rejected"))
    end

    it "says so when the detail was already decided" do
      phone.reject!(admin)

      patch approve_import_conflict_path(phone)
      follow_redirect!

      expect(response.body).to include("Someone already decided this")
      expect(service.reload.phone).to eq("250-555-0101")
    end

    it "points to the review from the service's page" do
      get service_path(service)

      expect(response.body).to include("A re-import would change 2 details of this service")
    end

    it "counts waiting details on the admin console" do
      allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([]))

      get admin_path

      panel = Nokogiri::HTML(response.body).at_css("[aria-label='Administration sections'] a[href='#{import_conflicts_path}']")
      expect(panel.text.squish).to include("Import review 2")
    end
  end
end
