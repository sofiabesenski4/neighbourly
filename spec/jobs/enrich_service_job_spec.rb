require "rails_helper"

RSpec.describe EnrichServiceJob do
  include ActiveJob::TestHelper

  let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv", enrich_documents: true) }
  let(:service) { source.services.create!(name: "Harbour Meals", enrichment_requested: true) }
  let(:enricher) { instance_double(ContentPipeline::Enricher, enrich!: true) }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    allow(ContentPipeline::Enricher).to receive(:new).and_return(enricher)
  end

  it "runs apart from chat replies, which keep a worker of their own" do
    workers = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/queue.yml"))["production"]["workers"]
    reserved = workers.select { |worker| Array(worker["queues"]) == [ChatResponseJob.new.queue_name] }

    expect(described_class.new.queue_name).to eq("enrichment")
    expect(reserved).not_to be_empty
  end

  it "enriches the service" do
    described_class.perform_now(service)

    expect(ContentPipeline::Enricher).to have_received(:new).with(service)
    expect(enricher).to have_received(:enrich!)
  end

  it "skips a service that is already enriched" do
    service.update!(enriched_at: Time.current)

    described_class.perform_now(service)

    expect(enricher).not_to have_received(:enrich!)
  end

  it "skips a service nobody asked to enrich" do
    service.update!(enrichment_requested: false)

    described_class.perform_now(service)

    expect(enricher).not_to have_received(:enrich!)
  end

  it "runs after chat replies" do
    expect(described_class.new(service).priority).to be > ChatResponseJob.new(1, "hi").priority.to_i
  end

  it "runs one job per service at a time" do
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.new(service).concurrency_key).to eq(described_class.new(Service.find(service.id)).concurrency_key)
  end

  it "retries later when embedding the description is rate limited" do
    chat = instance_double(RubyLLM::Chat)
    allow(ContentPipeline::Enricher).to receive(:new).and_call_original
    allow(RubyLLM).to receive(:chat).and_return(chat)
    allow(chat).to receive_messages(with_instructions: chat, with_schema: chat,
      ask: instance_double(RubyLLM::Message, content: {name: "Harbour Meals", summary: "Lunches.", categories: []}.to_json))
    service
    allow(ContentPipeline::Embedder).to receive(:embed).and_raise(RubyLLM::RateLimitError, "slow down")

    expect { described_class.perform_now(service) }.to have_enqueued_job(described_class).with(service)
  end

  it "retries later when the connection to the model times out" do
    allow(enricher).to receive(:enrich!).and_raise(Faraday::TimeoutError, "timed out")

    expect { described_class.perform_now(service) }.to have_enqueued_job(described_class).with(service)
  end

  it "asks again later when the model's reply cannot be used" do
    allow(enricher).to receive(:enrich!).and_raise(ContentPipeline::Enricher::InvalidResponse, "The model returned no summary.")

    expect { described_class.perform_now(service) }.to have_enqueued_job(described_class).with(service)
  end

  it "retries later when the model is rate limited" do
    allow(enricher).to receive(:enrich!).and_raise(RubyLLM::RateLimitError, "slow down")

    expect { described_class.perform_now(service) }.to have_enqueued_job(described_class).with(service)
  end
end
