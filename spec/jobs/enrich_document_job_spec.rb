require "rails_helper"

RSpec.describe EnrichDocumentJob do
  include ActiveJob::TestHelper

  let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv") }
  let(:document) { source.documents.create!(content: "Name: Harbour Meals", external_id: "1", metadata: {"Name" => "Harbour Meals"}) }
  let(:enricher) { instance_double(ContentPipeline::Enricher, enrich!: true) }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    allow(ContentPipeline::Enricher).to receive(:new).and_return(enricher)
  end

  it "enriches the document" do
    described_class.perform_now(document)

    expect(ContentPipeline::Enricher).to have_received(:new).with(document)
    expect(enricher).to have_received(:enrich!)
  end

  it "skips a document that is already enriched" do
    document.update!(enriched_at: Time.current)

    described_class.perform_now(document)

    expect(enricher).not_to have_received(:enrich!)
  end

  it "skips documents that did not come from a CSV" do
    source.update!(source_type: "html", url: "https://example.com")

    described_class.perform_now(document)

    expect(enricher).not_to have_received(:enrich!)
  end

  it "retries later when the model is rate limited" do
    allow(enricher).to receive(:enrich!).and_raise(RubyLLM::RateLimitError, "slow down")

    expect { described_class.perform_now(document) }.to have_enqueued_job(described_class).with(document)
  end
end
