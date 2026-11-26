require "rails_helper"

RSpec.describe ImportConflict do
  let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv") }
  let(:admin) { User.create!(email: "review-admin@example.com", password: "password123", admin: true) }
  let(:service) do
    source.services.create!(name: "Harbour Meals", phone: "250-555-0101",
      address_attributes: {street_address: "100 Harbour St", city: "Victoria", lat: 48.43, lng: -123.37})
  end

  it "uses the import's value when approved, and records who decided" do
    conflict = service.import_conflicts.create!(field: "phone", incoming_value: "250-555-0199")

    freeze_time do
      expect(conflict.approve!(admin)).to be(true)

      expect(service.reload.phone).to eq("250-555-0199")
      expect(conflict.reload).to have_attributes(status: "approved", decided_by: admin, decided_at: Time.current)
    end
  end

  it "keeps the current value when rejected" do
    conflict = service.import_conflicts.create!(field: "phone", incoming_value: nil)

    expect(conflict.reject!(admin)).to be(true)

    expect(service.reload.phone).to eq("250-555-0101")
    expect(conflict.reload.status).to eq("rejected")
  end

  it "moves the address to the import's location, dropping coordinates that described the old one" do
    conflict = service.import_conflicts.create!(field: "address", incoming_value: {"street_address" => "200 Harbour St"})

    expect { conflict.approve!(admin) }.to have_enqueued_job(GeocodeAddressJob)

    expect(service.reload.address).to have_attributes(street_address: "200 Harbour St", city: nil, coordinates: nil)
  end

  it "links the organization the import names" do
    conflict = service.import_conflicts.create!(field: "organization", incoming_value: "Our Place Society")

    conflict.approve!(admin)

    expect(service.reload.organization).to have_attributes(name: "Our Place Society", source: source)
  end

  it "decides only once" do
    conflict = service.import_conflicts.create!(field: "phone", incoming_value: "250-555-0199")
    ImportConflict.find(conflict.id).reject!(admin)

    expect(conflict.approve!(admin)).to be(false)
    expect(service.reload.phone).to eq("250-555-0101")
  end

  it "treats the same value written differently as no change" do
    expect(described_class.writable?(service, "phone", " 250-555-0101 ")).to be(true)
    expect(described_class.writable?(service, "address", {street_address: "100 Harbour St", city: "Victoria"})).to be(true)
    expect(described_class.writable?(service, "address", {street_address: "100 Harbour St"})).to be(false)
  end
end
