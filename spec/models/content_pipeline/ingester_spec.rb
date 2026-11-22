require "rails_helper"

RSpec.describe ContentPipeline::Ingester do
  let(:source) { Source.create!(name: "Shelter list", url: "https://example.com/shelters.csv", source_type: "csv") }
  let(:ingester) { described_class.new(source) }
  let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }

  let(:feed) { "id,Name,City\n1,Test Shelter,Vancouver\n" }

  before do
    allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return(feed)
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
    %w[Food\ Banks Shelters].each { |name| Category.find_or_create_by!(name: name) }
  end

  describe "#call" do
    it "fetches, parses, embeds, and creates documents" do
      expect { ingester.call }.to change(Document, :count).by(1)

      doc = Document.last
      expect(doc.title).to eq("Test Shelter")
      expect(doc.content).to include("Name: Test Shelter")
      expect(doc.content).to include("City: Vancouver")
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
      let(:source) { Source.create!(name: "Test HTML", url: "https://example.com/page", source_type: "html") }

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

      expect { chunks = ingester.parse("Name\nTest\n") }.not_to change(Document, :count)
      expect(chunks.map { |chunk| chunk[:title] }).to eq(["Test"])
    end
  end

  describe "#ingest" do
    it "parses raw content directly without fetching from URL" do
      raw_csv = "id,Name\n99,Uploaded Shelter\n"

      expect_any_instance_of(ContentPipeline::Fetcher).not_to receive(:call)
      expect { ingester.ingest(raw_csv) }.to change(Document, :count).by(1)

      expect(Document.last.title).to eq("Uploaded Shelter")
    end

    it "updates last_fetched_at on the source" do
      freeze_time do
        ingester.ingest("Name\nTest\n")
        expect(source.reload.last_fetched_at).to eq(Time.current)
      end
    end

    it "returns the number of chunks processed" do
      result = ingester.ingest("Name\nTest\n")
      expect(result).to eq(1)
    end

    context "with an HTML source and uploaded file content" do
      let(:source) { Source.create!(name: "Uploaded HTML", url: "https://example.com/upload", source_type: "html") }

      it "parses HTML content from the uploaded file" do
        html = "<html><head><title>Uploaded Page</title></head><body><p>Meals served daily.</p></body></html>"
        expect { ingester.ingest(html) }.to change(Document, :count).by(1)

        expect(Document.last.content).to include("Meals served daily")
      end

      it "writes a page's new text even when its title is unchanged" do
        ingester.ingest("<html><head><title>Page</title></head><body><p>Meals served daily.</p></body></html>")

        ingester.ingest("<html><head><title>Page</title></head><body><p>Meals served on weekdays.</p></body></html>")

        expect(Document.sole.content).to include("Meals served on weekdays.")
      end

      it "saves no services, because a page's chunks are search text" do
        html = "<html><head><title>Uploaded Page</title></head><body><p>Meals served daily.</p></body></html>"

        expect { ingester.ingest(html) }.not_to change(Service, :count)
      end
    end

    context "with a CSV source" do
      let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv", enrich_documents: true) }
      let(:csv) { "Name,Address\nHarbour Meals,100 Harbour St\nNorthside Shelter,22 North Rd\n" }

      it "creates one embedded document per row with the row in metadata" do
        expect { ingester.ingest(csv) }.to change(Document, :count).by(2)

        doc = source.documents.find_by!(title: "Harbour Meals")
        expect(doc.metadata).to eq("Name" => "Harbour Meals", "Address" => "100 Harbour St")
        expect(doc.content).to eq("Name: Harbour Meals\nAddress: 100 Harbour St")
        expect(doc.categories).to be_empty
        expect(doc.embedding).not_to be_nil
      end

      it "queues enrichment for each new row's service, whether uploaded or fetched from a URL" do
        source.update!(url: "https://example.com/centres.csv")
        allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return(csv)

        expect { ingester.call }.to have_enqueued_job(EnrichServiceJob).exactly(2).times
        expect(source.services).to all(be_awaiting_enrichment)
      end

      it "queues enrichment for unchanged rows once the source starts using AI" do
        source.update!(enrich_documents: false)
        ingester.ingest(csv)
        source.update!(enrich_documents: true)

        expect { described_class.new(source).ingest(csv) }.to have_enqueued_job(EnrichServiceJob).exactly(2).times
        expect(source.services).to all(be_awaiting_enrichment)
      end

      it "queues no enrichment when the source did not opt in" do
        source.update!(enrich_documents: false)

        expect { ingester.ingest(csv) }.not_to have_enqueued_job(EnrichServiceJob)
        expect(source.services).to all(have_attributes(enrichment_requested: false))
      end

      it "still queues enrichment for rows saved before a later row fails" do
        calls = 0
        allow(ContentPipeline::Embedder).to receive(:embed) do
          calls += 1
          raise RubyLLM::Error, "embedding service unavailable" if calls == 2
          fake_vector
        end

        expect { ingester.ingest(csv) }.to raise_error(ActiveRecord::RecordNotSaved)
        expect(EnrichServiceJob).to have_been_enqueued.with(source.documents.find_by!(title: "Harbour Meals").service)
      end

      it "queues enrichment only for services this ingestion wrote that are still waiting" do
        ingester.ingest(csv)
        source.documents.find_by!(title: "Harbour Meals").service.update!(enriched_at: Time.current)
        stale = source.services.create!(name: "Gone", enrichment_requested: true)

        expect { described_class.new(source).ingest(csv) }.to have_enqueued_job(EnrichServiceJob).exactly(:once)
        expect(EnrichServiceJob).not_to have_been_enqueued.with(stale)
      end

      it "does not duplicate documents when the same file is ingested again" do
        ingester.ingest(csv)

        expect { ingester.ingest(csv) }.not_to change(Document, :count)
      end

      # Enrichment fills in services now, so rows keep what their file said.
      it "never rewrites a row with a summary" do
        ingester.ingest(csv)

        expect(source.documents.find_by!(title: "Harbour Meals").content).to eq("Name: Harbour Meals\nAddress: 100 Harbour St")
      end

      context "when a row's service was already enriched" do
        let(:csv) { "id,Name,Address\n1,Harbour Meals,100 Harbour St\n" }
        let(:document) { source.documents.find_by!(external_id: "1") }
        let(:service) { document.service }

        before do
          ingester.ingest(csv)
          service.update!(enriched_description: "Free lunches.", enriched_at: Time.current, hours: "Noon")
        end

        it "keeps the enrichment when the row is unchanged" do
          expect { described_class.new(source).ingest(csv) }.not_to(change { service.reload.attributes })
        end

        it "keeps the enrichment when the only difference is coordinates from geocoding" do
          document.update_columns(metadata: document.metadata.merge("lat" => 48.43, "lng" => -123.37))

          expect { described_class.new(source).ingest(csv) }.not_to have_enqueued_job(EnrichServiceJob)
          expect(service.reload).to have_attributes(enriched_description: "Free lunches.", enriched_at: be_present)
        end

        context "when the file supplies its own coordinates" do
          let(:csv) { "id,Name,Address,lat,lng\n1,Harbour Meals,100 Harbour St,48.43,-123.37\n" }

          it "sets the service again when those coordinates change" do
            described_class.new(source).ingest(csv.sub("48.43", "48.50"))

            expect(service.reload).to have_attributes(enriched_at: nil, enriched_description: nil)
            expect(document.reload.metadata).to include("lat" => "48.50")
          end
        end

        it "clears enrichment that lands while a changed row is being replaced" do
          allow(source.documents).to receive(:find_or_initialize_by).and_wrap_original do |original, **attributes|
            original.call(**attributes).tap do
              Service.where(id: service.id).update_all(enriched_at: Time.current, enriched_description: "Summary of the old row.")
            end
          end

          described_class.new(source).ingest(csv.sub("100 Harbour St", "200 Harbour St"))

          expect(service.reload).to have_attributes(enriched_at: nil, enriched_description: nil, embedding: nil)
        end

        it "clears enrichment that lands after the importer read the service" do
          service.update_columns(enriched_at: nil, enriched_description: nil)
          allow_any_instance_of(Document).to receive(:save_with_category_names!).and_wrap_original do |original, *arguments|
            original.call(*arguments).tap do
              original.receiver.service
              Service.where(id: service.id).update_all(enriched_at: Time.current, enriched_description: "Summary of the old row.")
            end
          end

          described_class.new(source).ingest(csv.sub("100 Harbour St", "200 Harbour St"))

          expect(service.reload).to have_attributes(enriched_at: nil, enriched_description: nil)
        end

        it "sets the service's address again from a changed row, and waits for enrichment to look it up" do
          service.address.update_columns(city: "Victoria", lat: 48.43, lng: -123.37)

          # Only the row's own address is looked up now. The service's waits.
          expect { described_class.new(source).ingest(csv.sub("100 Harbour St", "200 Harbour St")) }
            .to have_enqueued_job(GeocodeAddressJob).exactly(:once)

          expect(service.reload.address).to have_attributes(street_address: "200 Harbour St", city: nil, coordinates: nil)
          expect(service).to be_awaiting_enrichment
        end

        it "rewrites the row and clears what enrichment gave its service when the row changed" do
          expect { described_class.new(source).ingest(csv.sub("100 Harbour St", "200 Harbour St")) }
            .to have_enqueued_job(EnrichServiceJob).with(service)

          expect(document.reload).to have_attributes(title: "Harbour Meals", content: "id: 1\nName: Harbour Meals\nAddress: 200 Harbour St")
          expect(service.reload).to have_attributes(hours: nil, enriched_at: nil, enriched_description: nil)
        end
      end

      describe "services" do
        let(:csv) do
          "id,Name,Organization,Address,Phone,Ages\n" \
            "1,Harbour Meals,Harbourside Society,100 Harbour St,250-555-0101,All ages\n" \
            "2,Night Shelter,harbourside  SOCIETY,22 North Rd,,19+\n" \
            "3,Bike Repair,,5 Cook St,,\n"
        end

        context "when a row has no name column" do
          let(:csv) { "id,Address,Ages\n1,100 Harbour St,19+\n" }

          it "leaves the service for enrichment to name when the source asks for it" do
            source.update!(enrich_documents: true)

            expect { ingester.ingest(csv) }.to have_enqueued_job(EnrichServiceJob)
            expect(Service.sole).to have_attributes(name: nil, display_name: "Unnamed service", enrichment_requested: true)
          end

          it "names the service by the row's first value when nothing will enrich it" do
            source.update!(enrich_documents: false)
            ingester.ingest(csv)

            expect(Service.sole.name).to eq("1")
          end
        end

        it "saves a service for each row, linked to its document" do
          expect { ingester.ingest(csv) }.to change(Service, :count).by(3)

          document = source.documents.find_by!(external_id: "1")
          expect(document.service).to have_attributes(
            name: "Harbour Meals", phone: "250-555-0101", source: source, additional_details: {"Ages" => "All ages"}
          )
          expect(document.service.address).to have_attributes(street_address: "100 Harbour St", addressable: document.service)
        end

        it "links rows naming the same organization to one organization, first seen in this source" do
          ingester.ingest(csv)

          organization = Organization.sole
          expect(organization).to have_attributes(name: "Harbourside Society", source: source)
          expect(organization.services.map(&:name)).to contain_exactly("Harbour Meals", "Night Shelter")
          expect(source.services.find_by!(name: "Bike Repair").organization).to be_nil
        end

        it "doesn't duplicate services when the same file is ingested again" do
          ingester.ingest(csv)

          expect { described_class.new(source).ingest(csv) }.not_to change(Service, :count)
        end

        it "sets a changed row's service again, clearing what the row no longer says" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service
          service.address.update_columns(city: "Victoria", lat: 48.43, lng: -123.37)

          described_class.new(source).ingest(csv.sub("100 Harbour St,250-555-0101,All ages", "200 Harbour St,,All ages"))

          expect(service.reload.phone).to be_nil
          expect(service.address).to have_attributes(street_address: "200 Harbour St", city: nil, coordinates: nil)
        end

        # A member renames their organization, and someone else later adds one
        # under the old name. The member's service must stay with them.
        it "keeps a service with its renamed organization when another now has the old name" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service
          renamed = service.organization
          renamed.update!(name: "Harbourside Community Society")
          Organization.create!(name: "Harbourside Society")

          described_class.new(source).ingest(csv.sub("250-555-0101", "250-555-0199"))

          expect(service.reload).to have_attributes(phone: "250-555-0199", organization: renamed)
        end

        it "gives a new row naming the old name to the renamed organization its source already uses" do
          ingester.ingest(csv)
          renamed = source.documents.find_by!(external_id: "1").service.organization
          renamed.update!(name: "Harbourside Community Society")
          other = Organization.create!(name: "Harbourside Society")

          described_class.new(source).ingest(csv + "4,Breakfast Club,Harbourside Society,9 Wharf St,,\n")

          expect(source.documents.find_by!(external_id: "4").service.organization).to eq(renamed)
          expect(Organization.for_name("Harbourside Society")).to eq(other)
        end

        # Someone uploading the details signs off on them again, even unchanged.
        # A scheduled refresh confirms nothing.
        it "confirms every service an upload brings in, as the person uploading it" do
          uploader = User.create!(email: "uploader@example.com", password: "password123")
          ingester.ingest(csv)
          expect(source.services.pluck(:confirmed_at)).to all(be_nil)
          service = source.documents.find_by!(external_id: "1").service
          service.confirm!(by: User.create!(email: "checker@example.com", password: "password123"), method: "phone")

          travel_to(1.day.from_now) { described_class.new(source, confirmed_by: uploader).ingest(csv.sub("Bike Repair", "Bike Shop")) }

          expect(source.services.reload).to all(have_attributes(confirmed_by: uploader, confirmation_method: "upload"))
          expect(service.reload.confirmed_at).to be > 12.hours.from_now
        end

        # Nobody has checked what a changed row now says.
        it "clears a service's confirmation when a detail it vouched for changes, and keeps it otherwise" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service
          service.confirm!(by: User.create!(email: "checker@example.com", password: "password123"), method: "phone")

          described_class.new(source).ingest(csv)
          expect(service.reload.confirmation_method).to eq("phone")

          # The row reads differently, but names the same organization and details.
          described_class.new(source).ingest(csv.sub("Meals,Harbourside Society", "Meals,harbourside  SOCIETY"))
          expect(service.reload.confirmation_method).to eq("phone")

          described_class.new(source).ingest(csv.sub("250-555-0101", "250-555-0199"))
          expect(service.reload).to have_attributes(confirmed_at: nil, confirmed_by: nil, confirmation_method: nil)
        end

        it "keeps a service's coordinates when its row changes elsewhere" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service
          service.address.update_columns(lat: 48.43, lng: -123.37)

          described_class.new(source).ingest(csv.sub("250-555-0101", "250-555-0199"))

          expect(service.reload).to have_attributes(phone: "250-555-0199", coordinates: GeoPoint.new(lat: 48.43, lng: -123.37))
        end

        it "keeps admin edits to a service when its row comes in unchanged" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service
          service.update!(hours: "Daily 11am-1pm")

          described_class.new(source).ingest(csv)

          expect(service.reload.hours).to eq("Daily 11am-1pm")
        end

        it "gives an unchanged row a service again when an admin deleted it" do
          ingester.ingest(csv)
          document = source.documents.find_by!(external_id: "1")
          document.update!(enriched_at: Time.current)
          document.service.destroy!

          expect { described_class.new(source).ingest(csv) }.to change(Service, :count).by(1)
          expect(document.reload.service.name).to eq("Harbour Meals")
        end

        it "saves no document when its service can't be saved" do
          allow_any_instance_of(Service).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)

          expect { ingester.ingest(csv) }.to raise_error(ActiveRecord::RecordInvalid)
          expect(Document.count).to eq(0)
        end
      end

      it "writes no documents when the file is malformed" do
        expect { ingester.ingest("Name\n\"unclosed\n") }.to raise_error(ContentPipeline::Parsers::ParseError)
        expect(Document.count).to eq(0)
      end
    end
  end
end
