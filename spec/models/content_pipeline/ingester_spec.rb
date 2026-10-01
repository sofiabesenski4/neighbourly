require "rails_helper"

RSpec.describe ContentPipeline::Ingester do
  let(:source) { Source.create!(name: "Test API", url: "https://example.com/api", source_type: "api") }
  let(:ingester) { described_class.new(source) }
  let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }

  let(:api_response) do
    [{"id" => 1, "post_title" => "Test Shelter", "location" => {"city" => {"label" => "Vancouver"}}}].to_json
  end

  before do
    allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return(api_response)
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
  end

  describe "#call" do
    it "fetches, parses, embeds, and creates documents" do
      expect { ingester.call }.to change(Document, :count).by(1)

      doc = Document.last
      expect(doc.title).to eq("Test Shelter")
      expect(doc.content).to include("Test Shelter")
      expect(doc.content).to include("City: Vancouver")
      expect(doc.source).to eq(source)
      expect(doc.embedding).not_to be_nil
    end

    it "updates the source's last_fetched_at timestamp" do
      freeze_time do
        ingester.call
        expect(source.reload.last_fetched_at).to eq(Time.current)
      end
    end

    it "returns the number of chunks processed" do
      expect(ingester.call).to eq(1)
    end

    it "upserts documents based on external_id (no duplicates)" do
      ingester.call
      expect { ingester.call }.not_to change(Document, :count)

      # Content is updated in place
      expect(Document.count).to eq(1)
    end

    context "with an HTML source" do
      let(:source) { Source.create!(name: "Test HTML", url: "https://example.com/page", source_type: "html", css_selector: ".content") }

      let(:html_response) do
        <<~HTML
          <html>
            <head><title>Resource Page</title></head>
            <body>
              <div class="content">
                <p>Free meals available daily at 100 Harbour St.</p>
              </div>
            </body>
          </html>
        HTML
      end

      before do
        allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return(html_response)
      end

      it "uses the HTML parser and creates documents" do
        expect { ingester.call }.to change(Document, :count).by(1)

        doc = Document.last
        expect(doc.content).to include("Free meals available daily")
        expect(doc.title).to eq("Resource Page")
      end
    end
  end

  describe "#ingest" do
    it "parses raw content directly without fetching from URL" do
      raw_json = [{"id" => 99, "post_title" => "Uploaded Shelter"}].to_json

      expect_any_instance_of(ContentPipeline::Fetcher).not_to receive(:call)
      expect { ingester.ingest(raw_json) }.to change(Document, :count).by(1)

      expect(Document.last.title).to eq("Uploaded Shelter")
    end

    it "updates last_fetched_at on the source" do
      freeze_time do
        ingester.ingest([{"id" => 1, "post_title" => "Test"}].to_json)
        expect(source.reload.last_fetched_at).to eq(Time.current)
      end
    end

    it "returns the number of chunks processed" do
      result = ingester.ingest([{"id" => 1, "post_title" => "Test"}].to_json)
      expect(result).to eq(1)
    end

    context "with an HTML source and uploaded file content" do
      let(:source) { Source.create!(name: "Uploaded HTML", url: "https://example.com/upload", source_type: "html") }

      it "parses HTML content from the uploaded file" do
        html = "<html><head><title>Uploaded Page</title></head><body><p>Meals served daily.</p></body></html>"
        expect { ingester.ingest(html) }.to change(Document, :count).by(1)

        expect(Document.last.content).to include("Meals served daily")
      end
    end
  end
end
