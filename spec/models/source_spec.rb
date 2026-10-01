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

    it "requires a unique url" do
      Source.create!(name: "First", url: "https://example.com/data", source_type: "api")
      duplicate = build_source(name: "Second", url: "https://example.com/data")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:url]).to include("has already been taken")
    end

    it "requires a source_type" do
      source = build_source(source_type: nil)
      expect(source).not_to be_valid
    end

    it "only allows api, html, or form as source_type" do
      expect(build_source(source_type: "api")).to be_valid
      expect(build_source(source_type: "html")).to be_valid
      expect(build_source(source_type: "form", url: nil)).to be_valid
      expect(build_source(source_type: "rss")).not_to be_valid
    end

    it "does not require a url for form sources" do
      source = build_source(source_type: "form", url: nil)
      expect(source).to be_valid
    end
  end

  describe "scopes" do
    before do
      Source.create!(name: "API Source", url: "https://example.com/api", source_type: "api")
      Source.create!(name: "HTML Source", url: "https://example.com/page", source_type: "html")
    end

    it ".api_sources returns only api sources" do
      expect(Source.api_sources.pluck(:name)).to eq(["API Source"])
    end

    it ".html_sources returns only html sources" do
      expect(Source.html_sources.pluck(:name)).to eq(["HTML Source"])
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

  describe "associations" do
    it "destroys associated documents when destroyed" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))

      source = Source.create!(name: "Test", url: "https://example.com", source_type: "api")
      source.documents.create!(content: "test content", external_id: "1")

      expect { source.destroy! }.to change(Document, :count).by(-1)
    end
  end
end
