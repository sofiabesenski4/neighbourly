require "rails_helper"

RSpec.describe Source, type: :model do
  def build_source(**overrides)
    Source.new(
      {name: "Test Source", url: "https://example.com/data", source_type: "api"}.merge(overrides)
    )
  end

  describe "validations" do
    it "is valid with valid attributes" do
      source = build_source
      expect(source).to be_valid
    end

    it "requires a name" do
      source = build_source(name: nil)
      expect(source).not_to be_valid
      expect(source.errors[:name]).to include("can't be blank")
    end

    it "requires a url for html sources" do
      source = build_source(source_type: "html", url: nil)
      expect(source).not_to be_valid
      expect(source.errors[:url]).to include("can't be blank")
    end

    it "does not require a url for api sources" do
      source = build_source(source_type: "api", url: nil)
      expect(source).to be_valid
    end

    it "allows two sources to share a url" do
      Source.create!(name: "First", url: "https://example.com/data", source_type: "api")
      expect { build_source(name: "Second", url: "https://example.com/data").save! }
        .to change(Source.where(url: "https://example.com/data"), :count).by(1)
    end

    it "requires a source_type" do
      source = build_source(source_type: nil)
      expect(source).not_to be_valid
    end

    it "only allows api, html, form, or csv as source_type" do
      expect(build_source(source_type: "api")).to be_valid
      expect(build_source(source_type: "html")).to be_valid
      expect(build_source(source_type: "form", url: nil)).to be_valid
      expect(build_source(source_type: "csv")).to be_valid
      expect(build_source(source_type: "rss")).not_to be_valid
    end

    it "does not require a url for form sources" do
      source = build_source(source_type: "form", url: nil)
      expect(source).to be_valid
    end

    it "only allows known ingestion statuses" do
      expect(build_source(ingestion_status: nil)).to be_valid
      expect(build_source(ingestion_status: "pending")).to be_valid
      expect(build_source(ingestion_status: "queued")).not_to be_valid
    end

    it "does not require a url for csv sources" do
      source = build_source(source_type: "csv", url: nil)
      expect(source).to be_valid
    end

    it "stores a blank url as nil" do
      expect(build_source(source_type: "csv", url: "  ").url).to be_nil
    end

    it "allows several sources without a url" do
      Source.create!(name: "First upload", source_type: "csv", url: "")
      second = Source.create!(name: "Second upload", source_type: "csv", url: "")

      expect(second.reload.url).to be_nil
    end
  end

  describe "scopes" do
    before do
      Source.create!(name: "API Source", url: "https://example.com/api", source_type: "api")
      Source.create!(name: "HTML Source", url: "https://example.com/page", source_type: "html")
      Source.create!(name: "CSV Source", source_type: "csv")
    end

    it ".api_sources returns only api sources" do
      expect(Source.api_sources.pluck(:name)).to eq(["API Source"])
    end

    it ".html_sources returns only html sources" do
      expect(Source.html_sources.pluck(:name)).to eq(["HTML Source"])
    end

    it ".csv_sources returns only csv sources" do
      expect(Source.csv_sources.pluck(:name)).to eq(["CSV Source"])
    end

    it ".fetchable returns only parsed sources with a url" do
      Source.create!(name: "Linked CSV", url: "https://example.com/data.csv", source_type: "csv")
      Source.form_entry_source

      expect(Source.fetchable.pluck(:name)).to contain_exactly("API Source", "HTML Source", "Linked CSV")
    end
  end

  describe "#api?, #html?, and #form?" do
    it "returns true for matching type" do
      api_source = build_source(source_type: "api")
      html_source = build_source(source_type: "html")
      form_source = build_source(source_type: "form", url: nil)

      expect(api_source.api?).to be true
      expect(api_source.html?).to be false
      expect(api_source.form?).to be false
      expect(html_source.html?).to be true
      expect(html_source.api?).to be false
      expect(form_source.form?).to be true
      expect(form_source.api?).to be false
      expect(build_source(source_type: "csv", url: nil).csv?).to be true
      expect(api_source.csv?).to be false
    end
  end

  describe "#enrich_documents?" do
    it "is off unless an admin opts in" do
      expect(build_source(source_type: "csv", url: nil).enrich_documents?).to be false
      expect(build_source(source_type: "csv", url: nil, enrich_documents: true).enrich_documents?).to be true
    end

    it "is off for sources other than CSV, whatever was chosen" do
      expect(build_source(source_type: "html", enrich_documents: true).enrich_documents?).to be false
    end
  end

  describe ".form_entry_source" do
    it "creates a form source if none exists" do
      expect { Source.form_entry_source }.to change(Source, :count).by(1)

      source = Source.form_entry_source
      expect(source.name).to eq("Form Entries")
      expect(source.source_type).to eq("form")
    end

    it "returns the existing form source on subsequent calls" do
      Source.form_entry_source
      expect { Source.form_entry_source }.not_to change(Source, :count)
    end
  end

  describe "page refreshes" do
    let(:source) { Source.create!(name: "Uploaded", source_type: "csv", ingestion_status: :pending) }

    it "refreshes pages showing the source when it changes" do
      source

      expect { source.update!(ingestion_status: :ingesting) }
        .to have_enqueued_job(Turbo::Streams::BroadcastStreamJob).with(source.to_gid_param, content: include("refresh"))
    end

    it "refreshes the sources list when a source is created" do
      expect { source }
        .to have_enqueued_job(Turbo::Streams::BroadcastStreamJob).with("sources", content: include("refresh"))
    end

    it "refreshes the sources list when a source changes" do
      source

      expect { source.update!(ingestion_status: :failed) }
        .to have_enqueued_job(Turbo::Streams::BroadcastStreamJob).with("sources", content: include("refresh"))
    end

    it "refreshes the sources list when a source is deleted" do
      source

      expect { source.destroy! }
        .to have_enqueued_job(Turbo::Streams::BroadcastStreamJob).with("sources", content: include("refresh"))
    end
  end

  describe "associations" do
    it "destroys associated documents when destroyed" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))

      source = Source.create!(name: "Test", url: "https://example.com", source_type: "api")
      source.documents.create!(content: "test content", external_id: "1")

      expect { source.destroy! }.to change(Document, :count).by(-1)
    end
  end
end
