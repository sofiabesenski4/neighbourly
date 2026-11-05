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

  it "runs after chat replies" do
    expect(described_class.new(document).priority).to be > ChatResponseJob.new(1, "hi").priority.to_i
  end

  it "runs one job per document at a time" do
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.new(document).concurrency_key).to eq(described_class.new(Document.find(document.id)).concurrency_key)
  end

  it "retries later when embedding the summary is rate limited" do
    chat = instance_double(RubyLLM::Chat)
    allow(ContentPipeline::Enricher).to receive(:new).and_call_original
    allow(RubyLLM).to receive(:chat).and_return(chat)
    allow(chat).to receive_messages(with_instructions: chat, with_schema: chat,
      ask: instance_double(RubyLLM::Message, content: {title: "Harbour Meals", summary: "Lunches.", categories: []}.to_json))
    document
    allow(ContentPipeline::Embedder).to receive(:embed).and_raise(RubyLLM::RateLimitError, "slow down")

    expect { described_class.perform_now(document) }.to have_enqueued_job(described_class).with(document)
  end

  it "retries later when the model is rate limited" do
    allow(enricher).to receive(:enrich!).and_raise(RubyLLM::RateLimitError, "slow down")

    expect { described_class.perform_now(document) }.to have_enqueued_job(described_class).with(document)
  end
end
