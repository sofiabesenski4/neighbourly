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

  it "reads and writes the province as the state" do
    service = Service.new(state: "WA")

    expect(service.province).to eq("WA")
    expect(service.state).to eq("WA")
  end

  it "stores blank details as empty" do
    expect(service(phone: "  ", city: " Victoria ").attributes.values_at("phone", "city")).to eq([nil, "Victoria"])
  end

  it "keeps details that have no column of their own" do
    created = service(details: {languages: ["English", "Punjabi"], intake: {referral: false, steps: ["Call ahead"]}})

    expect(created.reload.details).to eq(
      "languages" => ["English", "Punjabi"],
      "intake" => {"referral" => false, "steps" => ["Call ahead"]}
    )
  end

  it "has no details until some are given" do
    expect(service.details).to eq({})
    expect(service(details: nil).details).to eq({})
  end

  it "only keeps details as named values" do
    expect(source.services.build(name: "Community lunch", details: ["languages"])).not_to be_valid
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

  describe "finding coordinates" do
    it "queues a lookup for a street address in BC" do
      expect { service(address_line: "919 Pandora Ave", city: "Victoria", province: "British Columbia") }
        .to have_enqueued_job(GeocodeAddressJob)
    end

    it "takes a service with no province or country to be in BC" do
      expect(Service.new(address_line: "919 Pandora Ave", city: "Victoria").geocoding_query)
        .to eq("919 Pandora Ave, Victoria, BC")
    end

    # The geocoder only knows BC, so it would place these at the wrong address.
    it "doesn't look up an address outside BC" do
      expect { service(address_line: "400 Broad St", city: "Seattle", state: "WA") }
        .not_to have_enqueued_job(GeocodeAddressJob)
      expect { service(address_line: "1 Main St", city: "Victoria", country: "Australia") }
        .not_to have_enqueued_job(GeocodeAddressJob)
    end

    it "uses coordinates it was given instead of looking them up" do
      created = nil

      expect { created = service(address_line: "919 Pandora Ave", lat: 48.42, lng: -123.35) }
        .not_to have_enqueued_job(GeocodeAddressJob)
      expect(created.coordinates).to eq(GeoPoint.new(lat: 48.42, lng: -123.35))
    end

    it "keeps coordinates when other details change" do
      created = service(address_line: "919 Pandora Ave", city: "Victoria", lat: 48.42, lng: -123.35)

      expect { created.update!(phone: "250-555-0199") }.not_to have_enqueued_job(GeocodeAddressJob)
      expect(created.reload.coordinates).to eq(GeoPoint.new(lat: 48.42, lng: -123.35))
    end

    it "drops coordinates and looks up again when the address changes" do
      created = service(address_line: "919 Pandora Ave", city: "Victoria", lat: 48.42, lng: -123.35)

      expect { created.update!(address_line: "535 Ellice St") }.to have_enqueued_job(GeocodeAddressJob)
      expect(created.reload.coordinates).to be_nil
    end

    it "waits while its row is waiting for enrichment" do
      source.update!(enrich_documents: true)
      document = source.documents.create!(title: "Row 1", content: "Name: Community lunch")

      expect { service(document: document, address_line: "919 Pandora Ave") }
        .not_to have_enqueued_job(GeocodeAddressJob)
    end
  end
end
