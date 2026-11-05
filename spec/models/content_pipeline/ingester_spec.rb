require "rails_helper"

RSpec.describe ContentPipeline::Ingester do
  let(:source) { Source.create!(name: "Test API", url: "https://example.com/api", source_type: "api") }
  let(:ingester) { described_class.new(source) }
  let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }

  let(:api_response) do
    [{"id" => 1, "post_title" => "Test Shelter", "location" => {"city" => {"label" => "Vancouver"}},
      "taxonomies" => [{"name" => "Food Banks"}, {"name" => "Shelters"}]}].to_json
  end

  before do
    allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return(api_response)
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
    %w[Food\ Banks Shelters].each { |name| Category.find_or_create_by!(name: name) }
  end

  describe "#call" do
    it "fetches, parses, embeds, and creates documents" do
      expect { ingester.call }.to change(Document, :count).by(1)

      doc = Document.last
      expect(doc.title).to eq("Test Shelter")
      expect(doc.content).to include("Test Shelter")
      expect(doc.content).to include("City: Vancouver")
      expect(doc.content).to include("Categories: Food Banks, Shelters")
      expect(doc.category_names).to eq(["Food Banks", "Shelters"])
      expect(doc.metadata).not_to have_key("categories")
      expect(doc.source).to eq(source)
      expect(doc.embedding).not_to be_nil
      expect(ContentPipeline::Embedder).to have_received(:embed).with(doc.content)
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

  describe "#parse" do
    it "returns chunks without writing documents" do
      chunks = nil

      expect { chunks = ingester.parse([{"id" => 1, "post_title" => "Test"}].to_json) }.not_to change(Document, :count)
      expect(chunks.map { |chunk| chunk[:title] }).to eq(["Test"])
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

    context "with a CSV source" do
      let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv") }
      let(:csv) { "Name,Address\nHarbour Meals,100 Harbour St\nNorthside Shelter,22 North Rd\n" }

      it "creates one embedded document per row with the row in metadata" do
        expect { ingester.ingest(csv) }.to change(Document, :count).by(2)

        doc = source.documents.find_by!(title: "Harbour Meals")
        expect(doc.metadata).to eq("Name" => "Harbour Meals", "Address" => "100 Harbour St")
        expect(doc.content).to eq("Name: Harbour Meals\nAddress: 100 Harbour St")
        expect(doc.categories).to be_empty
        expect(doc.embedding).not_to be_nil
      end

      it "queues enrichment for each new row, whether uploaded or fetched from a URL" do
        source.update!(url: "https://example.com/centres.csv")
        allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return(csv)

        expect { ingester.call }.to have_enqueued_job(EnrichDocumentJob).exactly(2).times
      end

      it "queues enrichment only for rows this ingestion wrote" do
        ingester.ingest(csv)
        source.documents.find_by!(title: "Harbour Meals").update!(enriched_at: Time.current)
        stale = source.documents.create!(content: "Name: Gone", external_id: "gone", metadata: {"Name" => "Gone"})

        expect { described_class.new(source).ingest(csv) }.to have_enqueued_job(EnrichDocumentJob).exactly(:once)
        expect(EnrichDocumentJob).not_to have_been_enqueued.with(stale)
      end

      it "does not duplicate documents when the same file is ingested again" do
        ingester.ingest(csv)

        expect { ingester.ingest(csv) }.not_to change(Document, :count)
      end

      context "when a row was already enriched" do
        let(:csv) { "id,Name,Address\n1,Harbour Meals,100 Harbour St\n" }
        let(:document) { source.documents.find_by!(external_id: "1") }

        before do
          ingester.ingest(csv)
          document.update!(title: "Harbour Community Meals", content: "Free lunches.", enriched_at: Time.current)
        end

        it "keeps the enrichment when the row is unchanged" do
          expect { described_class.new(source).ingest(csv) }.not_to(change { document.reload.attributes })
        end

        it "clears enrichment that lands while a changed row is being replaced" do
          document.update!(enriched_at: nil)
          allow(source.documents).to receive(:find_or_initialize_by).and_wrap_original do |original, **attributes|
            original.call(**attributes).tap do |loaded|
              Document.where(id: loaded.id).update_all(enriched_at: Time.current, content: "Summary of the old row.")
            end
          end

          described_class.new(source).ingest(csv.sub("100 Harbour St", "200 Harbour St"))

          expect(document.reload).to have_attributes(
            content: "id: 1\nName: Harbour Meals\nAddress: 200 Harbour St", enriched_at: nil
          )
        end

        it "rewrites the row and clears enrichment when the row changed" do
          described_class.new(source).ingest(csv.sub("100 Harbour St", "200 Harbour St"))

          expect(document.reload).to have_attributes(
            title: "Harbour Meals", content: "id: 1\nName: Harbour Meals\nAddress: 200 Harbour St", enriched_at: nil
          )
        end
      end

      it "writes no documents when the file is malformed" do
        expect { ingester.ingest("Name\n\"unclosed\n") }.to raise_error(ContentPipeline::Parsers::ParseError)
        expect(Document.count).to eq(0)
      end
    end
  end
end
