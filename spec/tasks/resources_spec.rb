require "rails_helper"
require "rake"

# Tests the catch-up task for addresses whose lookup failed or never ran.
# It checks which addresses get a lookup queued and what the task reports. The jobs
# are only queued, never run: geocode_address_job_spec.rb covers what they do.
RSpec.describe "resources rake tasks" do
  # Loading twice would register every task twice, so each would run twice. Other
  # task specs may already have loaded them in this process.
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?(:environment)
  end

  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    # Rake only runs a task once per process unless it's told it can run again.
    Rake::Task["resources:geocode"].reenable
  end

  # Saving with callbacks skipped creates an address just as one whose lookup failed
  # would look: a street address with no coordinates and no lookup queued.
  def existing_address(**details)
    document = source.documents.create!(content: "Resource")
    Address.insert!({document_id: document.id, **details})
    document.reload.address
  end

  def run_task
    Rake::Task["resources:geocode"].invoke
  end

  it "queues a lookup for an address with a street address and no coordinates" do
    address = existing_address(street_address: "919 Pandora Ave", city: "Victoria")

    expect { run_task }.to have_enqueued_job(GeocodeAddressJob).with(address).once
      .and output(/Queued 1 coordinate lookups/).to_stdout
  end

  it "skips an address that already has coordinates" do
    existing_address(street_address: "919 Pandora Ave", lat: 48.42, lng: -123.35)

    expect {
      expect { run_task }.not_to have_enqueued_job(GeocodeAddressJob)
    }.to output(/Queued 0 coordinate lookups/).to_stdout
  end

  it "leaves addresses waiting for enrichment to fill in" do
    source.update!(source_type: "csv", url: nil, enrich_documents: true)
    existing_address(street_address: "919 Pandora Ave")

    expect {
      expect { run_task }.not_to have_enqueued_job(GeocodeAddressJob)
    }.to output(/Left 1 addresses for enrichment to fill in/).to_stdout
  end

  # These can't be looked up, so the task reports them for someone to review.
  it "reports addresses it can't look up without a street address" do
    existing_address(city: "Victoria")

    expect { run_task }.to output(/Queued 0 coordinate lookups\nSkipped 1 addresses/).to_stdout
  end

  # Older resources keep their location in metadata until they are edited or imported again.
  it "leaves resources saved before addresses had their own table alone" do
    source.documents.create!(content: "Resource", metadata: {address: "919 Pandora Ave"})

    expect {
      expect { run_task }.not_to have_enqueued_job(GeocodeAddressJob)
    }.to output(/Queued 0 coordinate lookups/).to_stdout
  end

  # A rerun is how lookups get retried after an outage or a failed job.
  it "queues an address again on a later run if it still has no coordinates" do
    existing_address(street_address: "919 Pandora Ave")
    expect { run_task }.to output.to_stdout
    Rake::Task["resources:geocode"].reenable

    expect { run_task }.to have_enqueued_job(GeocodeAddressJob)
      .and output(/Queued 1 coordinate lookups/).to_stdout
  end
end
