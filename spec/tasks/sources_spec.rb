require "rails_helper"
require "rake"

RSpec.describe "sources rake tasks" do
  before(:all) do
    Rails.application.load_tasks
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

  describe "sources:enrich" do
    let(:csv_source) { Source.create!(name: "Drop-in Centres", source_type: "csv") }
    let!(:pending) { csv_source.documents.create!(content: "Name: A", external_id: "a", metadata: {"Name" => "A"}) }
    let!(:failing) { csv_source.documents.create!(content: "Name: B", external_id: "b", metadata: {"Name" => "B"}) }
    let(:enriched) { [] }

    before do
      csv_source.documents.create!(content: "Name: C", external_id: "c", metadata: {"Name" => "C"}, enriched_at: Time.current)
      html_source = Source.create!(name: "Shelters", url: "https://example.com", source_type: "html")
      html_source.documents.create!(content: "Shelter info", external_id: "s")

      allow(ContentPipeline::Enricher).to receive(:new) do |document|
        instance_double(ContentPipeline::Enricher).tap do |enricher|
          allow(enricher).to receive(:enrich!) do
            raise ContentPipeline::Enricher::InvalidResponse, "The model did not return JSON." if document == failing
            enriched << document
          end
        end
      end
      Rake::Task["sources:enrich"].reenable
    end

    it "enriches CSV documents not yet enriched and reports failures without stopping" do
      expect { Rake::Task["sources:enrich"].invoke }
        .to output(/Enriching 2 documents.*Finished enriching. 1 failed./m).to_stdout
        .and output(/Document #{failing.id} was not enriched: The model did not return JSON./).to_stderr

      expect(enriched).to eq([pending])
    end

    it "limits enrichment to one source when given an ID" do
      other = Source.create!(name: "Other", source_type: "csv")
      other.documents.create!(content: "Name: D", external_id: "d", metadata: {"Name" => "D"})

      expect { Rake::Task["sources:enrich"].invoke(other.id) }.to output(/Enriching 1 documents/).to_stdout
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
