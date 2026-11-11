require "rails_helper"

# Tests what GeocodeAddressJob does to an address once it runs: saving
# coordinates, leaving the address alone when it should, and retrying when the
# service is down. Geocoder itself is replaced with a fake here, because its own
# behaviour is covered by geocoder_spec.rb. Whether the job gets queued in the
# first place is covered by address_spec.rb.
RSpec.describe GeocodeAddressJob, type: :job do
  include ActiveJob::TestHelper

  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }
  let(:point) { GeoPoint.new(lat: 48.4271129, lng: -123.3577635) }

  # Saving a resource normally calls an embedding service. Tests must not.
  before { allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0)) }

  def address(**details)
    document = source.documents.build(content: "Resource")
    document.assign_address(**details)
    document.save!
    document.address
  end

  it "saves the coordinates alongside the address's other details" do
    allow(Geocoder).to receive(:locate).with("919 Pandora Ave, Victoria, BC").and_return(point)
    saved = address(street_address: "919 Pandora Ave", city: "Victoria", phone: "250-555-0100")

    described_class.perform_now(saved)

    expect(saved.reload.coordinates).to eq(point)
    expect(saved.phone).to eq("250-555-0100")
  end

  # Saving coordinates must not cost an embedding call or trigger another lookup.
  it "doesn't regenerate the embedding or queue itself again" do
    allow(Geocoder).to receive(:locate).and_return(point)
    saved = address(street_address: "919 Pandora Ave")
    clear_enqueued_jobs

    expect(ContentPipeline::Embedder).not_to receive(:embed)
    expect { described_class.perform_now(saved) }.not_to have_enqueued_job(described_class)
  end

  it "leaves the address without coordinates when there is no trustworthy match" do
    allow(Geocoder).to receive(:locate).and_return(nil)
    saved = address(street_address: "Behind the library")

    described_class.perform_now(saved)

    expect(saved.reload.coordinates).to be_nil
  end

  it "doesn't look up an address that already has coordinates" do
    saved = address(street_address: "919 Pandora Ave", lat: 48.4, lng: -123.3)
    expect(Geocoder).not_to receive(:locate)

    described_class.perform_now(saved)
  end

  # The fake lookup edits the address partway through, as a person could during
  # the real network call. The answer for the old address must not be saved.
  it "discards coordinates for an address edited during the lookup" do
    saved = address(street_address: "919 Pandora Ave")
    allow(Geocoder).to receive(:locate) do
      Address.find(saved.id).update!(street_address: "1 New St")
      point
    end

    described_class.perform_now(saved)

    expect(saved.reload.coordinates).to be_nil
    expect(saved.street_address).to eq("1 New St")
  end

  # retry_on handles the error by queueing the job again rather than raising it.
  it "retries later when the geocoder is unavailable" do
    allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable)
    saved = address(street_address: "919 Pandora Ave")
    clear_enqueued_jobs

    expect { described_class.perform_now(saved) }.to have_enqueued_job(described_class)
  end
end
