require "rails_helper"
require "rake"

RSpec.describe "sources rake tasks" do
  # Loading twice would register every task twice, so each would run twice. Other
  # task specs may already have loaded them in this process.
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?(:environment)
  end

  let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }

  before do
    allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return(
      [{"id" => 1, "post_title" => "Test Shelter"}].to_json
    )
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
  end

  describe "sources:ingest" do
    it "ingests a single source by ID" do
      source = Source.create!(name: "Test", url: "https://example.com/api", source_type: "api")

      expect { Rake::Task["sources:ingest"].invoke(source.id) }
        .to change(Document, :count).by(1)
        .and output(/Ingested 1 documents from 'Test'/).to_stdout
    end
  end

  describe "sources:ingest_all" do
    it "ingests all sources" do
      Source.create!(name: "Source A", url: "https://example.com/a", source_type: "api")
      Source.create!(name: "Source B", url: "https://example.com/b", source_type: "api")

      expect { Rake::Task["sources:ingest_all"].invoke }
        .to change(Document, :count).by(2)
        .and output(/Ingested 1 documents from 'Source A'/).to_stdout
    end

    it "skips sources with nothing to fetch" do
      Rake::Task["sources:ingest_all"].reenable
      Source.create!(name: "Fetched", url: "https://example.com/a", source_type: "api")
      Source.create!(name: "Uploaded CSV", source_type: "csv")
      Source.form_entry_source

      expect { Rake::Task["sources:ingest_all"].invoke }
        .to output("Ingested 1 documents from 'Fetched'\n").to_stdout
    end
  end
end
