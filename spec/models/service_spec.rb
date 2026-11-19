require "rails_helper"

# Jobs are only queued here, never run, so no lookup happens. What the job does
# is in geocode_address_job_spec.rb.
RSpec.describe Service, type: :model do
  let(:source) { Source.create!(name: "Directory", source_type: "csv") }

  before { allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0)) }

  def service(**attributes)
    source.services.create!(name: "Community lunch", **attributes)
  end

  it "needs a name and a source" do
    service = Service.new

    expect(service).not_to be_valid
    expect(service.errors.attribute_names).to include(:name, :source)
  end

  it "stores blank details as empty" do
    expect(service(phone: "  ", email: " info@example.org ").attributes.values_at("phone", "email")).to eq([nil, "info@example.org"])
  end

  it "keeps details that have no column of their own" do
    created = service(additional_details: {languages: ["English", "Punjabi"], intake: {referral: false, steps: ["Call ahead"]}})

    expect(created.reload.additional_details).to eq(
      "languages" => ["English", "Punjabi"],
      "intake" => {"referral" => false, "steps" => ["Call ahead"]}
    )
  end

  it "has no details until some are given" do
    expect(service.additional_details).to eq({})
    expect(service(additional_details: nil).additional_details).to eq({})
  end

  it "only keeps details as named values" do
    expect(source.services.build(name: "Community lunch", additional_details: ["languages"])).not_to be_valid
  end

  it "is offered by an organization when one is known" do
    organization = Organization.create!(name: "Our Place Society")

    expect(service(organization: organization).organization).to eq(organization)
    expect(service.organization).to be_nil
  end

  it "comes from at most one imported row, and outlives it" do
    document = source.documents.create!(title: "Row 1", content: "Name: Community lunch")
    first = service(document: document)

    expect(source.services.build(name: "Copy", document: document)).not_to be_valid

    document.destroy!
    expect(first.reload.document).to be_nil
  end

  it "is removed with its source" do
    service

    expect { source.destroy! }.to change(Service, :count).by(-1)
  end

  describe "its address" do
    it "keeps where it is, coordinates included, on its address rather than on itself" do
      created = service(address_attributes: {street_address: "919 Pandora Ave", city: "Victoria", lat: 48.42, lng: -123.35})

      expect(created.reload.address).to have_attributes(street_address: "919 Pandora Ave", city: "Victoria", addressable: created)
      expect(created.coordinates).to eq(GeoPoint.new(lat: 48.42, lng: -123.35))
      expect(Service.column_names).not_to include("lat", "lng", "city")
    end

    it "queues a lookup for its address" do
      expect { service(address_attributes: {street_address: "919 Pandora Ave", city: "Victoria"}) }
        .to have_enqueued_job(GeocodeAddressJob)
    end

    it "adds no address for blank location fields" do
      expect(service(address_attributes: {street_address: "", city: ""}).address).to be_nil
    end

    it "is cleared, not ignored, when its fields are blanked" do
      created = service(address_attributes: {street_address: "919 Pandora Ave"})

      created.update!(address_attributes: {id: created.address.id, street_address: ""})

      expect(created.reload.address.street_address).to be_nil
    end

    it "waits for enrichment while its row is waiting" do
      source.update!(enrich_documents: true)
      document = source.documents.create!(title: "Row 1", content: "Name: Community lunch")

      expect { service(document: document, address_attributes: {street_address: "919 Pandora Ave"}) }
        .not_to have_enqueued_job(GeocodeAddressJob)
    end

    it "is removed with the service" do
      created = service(address_attributes: {street_address: "919 Pandora Ave"})

      expect { created.destroy! }.to change(Address, :count).by(-1)
    end
  end
end
