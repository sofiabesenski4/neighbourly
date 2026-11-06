require "rails_helper"
require "rake"

# Tests the one-time catch-up task for resources saved before geocoding existed.
# It checks which resources get a lookup queued and what the task reports. The jobs
# are only queued, never run: geocode_document_job_spec.rb covers what they do.
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

  # update_columns skips callbacks, so this creates a resource just as one saved
  # before geocoding existed would look: an address with no lookup ever queued.
  def existing_resource(**metadata)
    source.documents.create!(content: "Resource").tap { |document| document.update_columns(metadata: metadata) }
  end

  def run_task
    Rake::Task["resources:geocode"].invoke
  end

  it "queues a lookup for a resource with an address and no coordinates" do
    document = existing_resource(address: "919 Pandora Ave", city: "Victoria")

    expect { run_task }.to have_enqueued_job(GeocodeDocumentJob).with(document).once
      .and output(/Queued 1 coordinate lookups/).to_stdout
  end

  it "skips a resource that already has coordinates" do
    existing_resource(address: "919 Pandora Ave", lat: 48.42, lng: -123.35)

    expect {
      expect { run_task }.not_to have_enqueued_job(GeocodeDocumentJob)
    }.to output(/Queued 0 coordinate lookups/).to_stdout
  end

  # These can't be looked up, so the task reports them for someone to review.
  it "reports resources it can't look up without an address" do
    existing_resource(city: "Victoria")

    expect { run_task }.to output(/Queued 0 coordinate lookups\nSkipped 1 resources/).to_stdout
  end

  # A rerun is how lookups get retried after an outage or a failed job.
  it "queues a resource again on a later run if it still has no coordinates" do
    existing_resource(address: "919 Pandora Ave")
    expect { run_task }.to output.to_stdout
    Rake::Task["resources:geocode"].reenable

    expect { run_task }.to have_enqueued_job(GeocodeDocumentJob)
      .and output(/Queued 1 coordinate lookups/).to_stdout
  end
end
