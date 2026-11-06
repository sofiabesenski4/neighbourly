require "rails_helper"

# Tests what GeocodeDocumentJob does to a resource once it runs: saving
# coordinates, leaving the resource alone when it should, and retrying when the
# service is down. Geocoder itself is replaced with a fake here, because its own
# behaviour is covered by geocoder_spec.rb. Whether the job gets queued in the
# first place is covered by document_spec.rb.
RSpec.describe GeocodeDocumentJob, type: :job do
  include ActiveJob::TestHelper

  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }
  let(:point) { GeoPoint.new(lat: 48.4271129, lng: -123.3577635) }

  # Saving a resource normally calls an embedding service. Tests must not.
  before { allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0)) }

  def resource(**metadata)
    source.documents.create!(content: "Resource", metadata: metadata)
  end

  it "saves the coordinates alongside the resource's other details" do
    allow(Geocoder).to receive(:locate).with("919 Pandora Ave, Victoria, BC").and_return(point)
    document = resource(address: "919 Pandora Ave", city: "Victoria", notes: "Bring a bag")

    described_class.perform_now(document)

    expect(document.reload.coordinates).to eq(point)
    expect(document.metadata["notes"]).to eq("Bring a bag")
  end

  # Saving coordinates must not cost an embedding call or trigger another lookup.
  it "doesn't regenerate the embedding or queue itself again" do
    allow(Geocoder).to receive(:locate).and_return(point)
    document = resource(address: "919 Pandora Ave")
    clear_enqueued_jobs

    expect(ContentPipeline::Embedder).not_to receive(:embed)
    expect { described_class.perform_now(document) }.not_to have_enqueued_job(described_class)
  end

  it "leaves the resource without coordinates when there is no trustworthy match" do
    allow(Geocoder).to receive(:locate).and_return(nil)
    document = resource(address: "Behind the library")

    described_class.perform_now(document)

    expect(document.reload.coordinates).to be_nil
  end

  it "doesn't look up a resource that already has coordinates" do
    document = resource(address: "919 Pandora Ave", lat: 48.4, lng: -123.3)
    expect(Geocoder).not_to receive(:locate)

    described_class.perform_now(document)
  end

  # The fake lookup edits the resource partway through, as a person could during
  # the real network call. The answer for the old address must not be saved.
  it "discards coordinates for an address edited during the lookup" do
    document = resource(address: "919 Pandora Ave")
    allow(Geocoder).to receive(:locate) do
      Document.find(document.id).update!(metadata: {address: "1 New St"})
      point
    end

    described_class.perform_now(document)

    expect(document.reload.coordinates).to be_nil
    expect(document.metadata["address"]).to eq("1 New St")
  end

  # retry_on handles the error by queueing the job again rather than raising it.
  it "retries later when the geocoder is unavailable" do
    allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable)
    document = resource(address: "919 Pandora Ave")
    clear_enqueued_jobs

    expect { described_class.perform_now(document) }.to have_enqueued_job(described_class)
  end
end
