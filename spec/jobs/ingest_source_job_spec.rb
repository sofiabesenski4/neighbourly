require "rails_helper"

RSpec.describe IngestSourceJob do
  include ActiveJob::TestHelper

  let(:csv) { "Name,Address\nHarbour Meals,100 Harbour St\nNorthside Shelter,22 North Rd\n" }
  let(:source) do
    Source.create!(name: "Drop-in Centres", source_type: "csv", upload_content: csv, ingestion_status: :pending)
  end

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
  end

  it "ingests the upload into documents" do
    expect { described_class.perform_now(source) }.to change(source.documents, :count).by(2)
  end

  it "marks the source succeeded and drops the stored upload" do
    described_class.perform_now(source)

    expect(source.reload).to be_ingestion_succeeded
    expect(source.upload_content).to be_nil
    expect(source.last_fetched_at).to be_present
  end

  it "is ingesting while documents are written" do
    statuses = []
    allow_any_instance_of(ContentPipeline::Ingester).to receive(:ingest).and_wrap_original do |original, *args|
      statuses << source.reload.ingestion_status
      original.call(*args)
    end

    described_class.perform_now(source)

    expect(statuses).to eq(["ingesting"])
  end

  it "does nothing when there is no upload left to ingest" do
    source.update!(upload_content: nil, ingestion_status: :succeeded)

    expect { described_class.perform_now(source) }.not_to change(Document, :count)
    expect(source.reload).to be_ingestion_succeeded
  end

  context "when ingestion fails" do
    before do
      allow(ContentPipeline::Embedder).to receive(:embed).and_raise(RubyLLM::Error, "embedding service unavailable")
    end

    it "marks the source failed with the reason and re-raises" do
      expect { described_class.perform_now(source) }.to raise_error(ActiveRecord::RecordNotSaved)

      expect(source.reload).to be_ingestion_failed
      expect(source.ingestion_error).to eq("Failed to generate embedding: embedding service unavailable")
    end

    it "keeps the upload so the job can be retried" do
      expect { described_class.perform_now(source) }.to raise_error(ActiveRecord::RecordNotSaved)

      expect(source.reload.upload_content).to eq(csv)
    end

    it "clears the previous error when retried" do
      expect { described_class.perform_now(source) }.to raise_error(ActiveRecord::RecordNotSaved)
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))

      described_class.perform_now(source)

      expect(source.reload).to be_ingestion_succeeded
      expect(source.ingestion_error).to be_nil
    end
  end

  it "uses the message of errors that do not come from a record" do
    allow_any_instance_of(ContentPipeline::Ingester).to receive(:ingest).and_raise(ContentPipeline::Parsers::ParseError, "could not be read as CSV")

    expect { described_class.perform_now(source) }.to raise_error(ContentPipeline::Parsers::ParseError)
    expect(source.reload.ingestion_error).to eq("could not be read as CSV")
  end

  it "runs one ingestion per source at a time" do
    other = Source.create!(name: "Other", source_type: "csv")

    expect(described_class.new(source).concurrency_key).to eq("IngestSourceJob/Source/#{source.id}")
    expect(described_class.new(other).concurrency_key).not_to eq(described_class.new(source).concurrency_key)
    expect(described_class.concurrency_limit).to eq(1)
  end

  it "is discarded when the source was deleted before it ran" do
    described_class.perform_later(source)
    source.destroy!

    expect { perform_enqueued_jobs }.not_to raise_error
  end
end
