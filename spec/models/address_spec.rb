require "rails_helper"

# Tests when saving an address decides it needs a coordinate lookup, and what
# happens to stored coordinates across edits. Jobs are only queued here, never
# run, so no lookup happens. What the job does is in geocode_address_job_spec.rb.
RSpec.describe Address, type: :model do
  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }

  before { allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0)) }

  def resource(**details)
    document = source.documents.build(content: "Resource")
    document.assign_address(**details)
    document.save!
    document
  end

  it "queues a lookup when a resource is saved with a street address" do
    expect { resource(street_address: "919 Pandora Ave", city: "Victoria") }
      .to have_enqueued_job(GeocodeAddressJob)
  end

  it "doesn't look up an address with only a city" do
    expect { resource(city: "Victoria", phone: "250-555-0100") }.not_to have_enqueued_job(GeocodeAddressJob)
  end

  it "uses coordinates supplied by an import instead of looking them up" do
    document = nil

    expect { document = resource(street_address: "919 Pandora Ave", lat: 48.42, lng: -123.35) }
      .not_to have_enqueued_job(GeocodeAddressJob)
    expect(document.coordinates).to eq(GeoPoint.new(lat: 48.42, lng: -123.35))
  end

  it "treats coordinates that aren't numbers as unknown" do
    expect(Address.new(lat: "north", lng: nil).coordinates).to be_nil
    expect(Address.new(lat: "north").lat).to be_nil
  end

  # The form and imports set the address on every save. Without this, fixing a
  # typo in a resource's phone number would erase its coordinates.
  it "keeps coordinates when other details change" do
    document = resource(street_address: "919 Pandora Ave", city: "Victoria", lat: 48.42, lng: -123.35)
    document.assign_address(street_address: "919 Pandora Ave", city: "Victoria", phone: "250-555-0199")

    expect { document.save! }.not_to have_enqueued_job(GeocodeAddressJob)
    expect(document.reload.coordinates).to eq(GeoPoint.new(lat: 48.42, lng: -123.35))
  end

  it "drops coordinates and looks up again when the address changes" do
    document = resource(street_address: "919 Pandora Ave", city: "Victoria", lat: 48.42, lng: -123.35)
    document.assign_address(street_address: "535 Ellice St", city: "Victoria")

    expect { document.save! }.to have_enqueued_job(GeocodeAddressJob)
    expect(document.reload.coordinates).to be_nil
  end

  it "is removed with its resource" do
    document = resource(street_address: "919 Pandora Ave")

    expect { document.destroy! }.to change(Address, :count).by(-1)
  end

  context "when the source enriches its rows" do
    let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv", enrich_documents: true) }

    it "waits for enrichment before looking up the address" do
      expect { resource(street_address: "919 Pandora Ave", city: "Victoria") }.not_to have_enqueued_job(GeocodeAddressJob)
    end
  end
end
