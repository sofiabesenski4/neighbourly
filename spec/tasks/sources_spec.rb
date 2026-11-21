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
    allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return("Name\nTest Shelter\n")
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
  end

  describe "sources:ingest" do
    it "ingests a single source by ID" do
      source = Source.create!(name: "Test", url: "https://example.com/api", source_type: "csv")

      expect { Rake::Task["sources:ingest"].invoke(source.id) }
        .to change(Document, :count).by(1)
        .and output(/Ingested 1 documents from 'Test'/).to_stdout
    end
  end

  describe "sources:enrich" do
    let(:csv_source) { Source.create!(name: "Drop-in Centres", source_type: "csv", enrich_documents: true) }
    let!(:pending) { csv_source.services.create!(name: "A", enrichment_requested: true) }
    let!(:failing) { csv_source.services.create!(name: "B", enrichment_requested: true) }
    let(:enriched) { [] }

    before do
      csv_source.services.create!(name: "C", enrichment_requested: true, enriched_at: Time.current)
      csv_source.services.create!(name: "Not asked")

      allow(ContentPipeline::Enricher).to receive(:new) do |service|
        instance_double(ContentPipeline::Enricher).tap do |enricher|
          allow(enricher).to receive(:enrich!) do
            raise ContentPipeline::Enricher::InvalidResponse, "The model did not return JSON." if service == failing
            enriched << service
          end
        end
      end
      Rake::Task["sources:enrich"].reenable
    end

    it "enriches services still waiting and reports failures without stopping" do
      expect { Rake::Task["sources:enrich"].invoke }
        .to output(/Enriching 2 services.*Finished enriching. 1 failed, 0 skipped/m).to_stdout
        .and output(/Service #{failing.id} was not enriched: The model did not return JSON./).to_stderr

      expect(enriched).to eq([pending])
    end

    it "catches up rows imported before their source started using AI" do
      row = csv_source.documents.create!(title: "Row", content: "Row")
      earlier = csv_source.services.create!(name: "Imported earlier", document: row)

      expect { Rake::Task["sources:enrich"].invoke }.to output(/Enriching 3 services/).to_stdout.and output.to_stderr

      expect(enriched).to contain_exactly(pending, earlier)
      expect(earlier.reload.enrichment_requested).to be(true)
    end

    it "skips services another run enriched after the task loaded them" do
      allow(ContentPipeline::Enricher).to receive(:new) do
        Service.where(id: [pending.id, failing.id]).update_all(enriched_at: Time.current)
        instance_double(ContentPipeline::Enricher, enrich!: false)
      end

      expect { Rake::Task["sources:enrich"].invoke }.to output(/0 failed, 2 skipped/).to_stdout
    end

    it "counts a service deleted mid-run as a failure and carries on" do
      allow(ContentPipeline::Enricher).to receive(:new) do |service|
        instance_double(ContentPipeline::Enricher).tap do |enricher|
          allow(enricher).to receive(:enrich!) do
            raise ActiveRecord::RecordNotFound, "Couldn't find Service" if service == pending
            enriched << service
            true
          end
        end
      end

      expect { Rake::Task["sources:enrich"].invoke }
        .to output(/1 failed/).to_stdout.and output(/Service #{pending.id} was not enriched/).to_stderr
      expect(enriched).to eq([failing])
    end

    it "limits enrichment to one source when given an ID" do
      other = Source.create!(name: "Other", source_type: "csv", enrich_documents: true)
      other.services.create!(name: "D", enrichment_requested: true)

      expect { Rake::Task["sources:enrich"].invoke(other.id) }.to output(/Enriching 1 services/).to_stdout
    end

    # Someone adding a service on the site can ask for it too.
    it "includes services added on the site that asked for enrichment" do
      Source.form_entry_source.services.create!(name: "E", enrichment_requested: true)

      expect { Rake::Task["sources:enrich"].invoke }.to output(/Enriching 3 services/).to_stdout
    end
  end

  describe "sources:ingest_all" do
    it "ingests all sources" do
      Source.create!(name: "Source A", url: "https://example.com/a", source_type: "csv")
      Source.create!(name: "Source B", url: "https://example.com/b", source_type: "csv")

      expect { Rake::Task["sources:ingest_all"].invoke }
        .to change(Document, :count).by(2)
        .and output(/Ingested 1 documents from 'Source A'/).to_stdout
    end

    it "skips sources with nothing to fetch" do
      Rake::Task["sources:ingest_all"].reenable
      Source.create!(name: "Fetched", url: "https://example.com/a", source_type: "csv")
      Source.create!(name: "Uploaded CSV", source_type: "csv")
      Source.form_entry_source

      expect { Rake::Task["sources:ingest_all"].invoke }
        .to output("Ingested 1 documents from 'Fetched'\n").to_stdout
    end
  end
end
