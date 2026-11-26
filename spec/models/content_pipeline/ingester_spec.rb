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

      it "queues enrichment for each new row, whether uploaded or fetched from a URL" do
        source.update!(url: "https://example.com/centres.csv")
        allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return(csv)

        expect { ingester.call }.to have_enqueued_job(EnrichDocumentJob).exactly(2).times
      end

      it "queues no enrichment when the source did not opt in" do
        source.update!(enrich_documents: false)

        expect { ingester.ingest(csv) }.not_to have_enqueued_job(EnrichDocumentJob)
      end

      it "still queues enrichment for rows saved before a later row fails" do
        calls = 0
        allow(ContentPipeline::Embedder).to receive(:embed) do
          calls += 1
          raise RubyLLM::Error, "embedding service unavailable" if calls == 2
          fake_vector
        end

        expect { ingester.ingest(csv) }.to raise_error(ActiveRecord::RecordNotSaved)
        expect(EnrichDocumentJob).to have_been_enqueued.with(source.documents.find_by!(title: "Harbour Meals"))
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

        it "keeps the enrichment when the only difference is coordinates from geocoding" do
          document.update_columns(metadata: document.metadata.merge("lat" => 48.43, "lng" => -123.37))

          expect { described_class.new(source).ingest(csv) }.not_to have_enqueued_job(EnrichDocumentJob)
          expect(document.reload).to have_attributes(
            content: "Free lunches.", enriched_at: be_present, metadata: hash_including("lat" => 48.43, "lng" => -123.37)
          )
        end

        context "when the file supplies its own coordinates" do
          let(:csv) { "id,Name,Address,lat,lng\n1,Harbour Meals,100 Harbour St,48.43,-123.37\n" }

          it "rewrites the row when those coordinates change" do
            described_class.new(source).ingest(csv.sub("48.43", "48.50"))

            expect(document.reload).to have_attributes(enriched_at: nil, metadata: hash_including("lat" => "48.50"))
          end
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

        it "sets the address again from a changed row, clearing what enrichment filled in" do
          document.address.update_columns(city: "Victoria", lat: 48.43, lng: -123.37)

          expect { described_class.new(source).ingest(csv.sub("100 Harbour St", "200 Harbour St")) }
            .not_to have_enqueued_job(GeocodeAddressJob)

          expect(document.reload.address).to have_attributes(street_address: "200 Harbour St", city: nil, coordinates: nil)
        end

        it "rewrites the row and clears enrichment when the row changed" do
          described_class.new(source).ingest(csv.sub("100 Harbour St", "200 Harbour St"))

          expect(document.reload).to have_attributes(
            title: "Harbour Meals", content: "id: 1\nName: Harbour Meals\nAddress: 200 Harbour St", enriched_at: nil
          )
        end
      end

      describe "services" do
        let(:csv) do
          "id,Name,Organization,Address,Phone,Ages\n" \
            "1,Harbour Meals,Harbourside Society,100 Harbour St,250-555-0101,All ages\n" \
            "2,Night Shelter,harbourside  SOCIETY,22 North Rd,,19+\n" \
            "3,Bike Repair,,5 Cook St,,\n"
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

        it "holds details a changed row would replace or clear, keeping the service's current values" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service
          service.address.update_columns(city: "Victoria", lat: 48.43, lng: -123.37)

          described_class.new(source).ingest(csv.sub("100 Harbour St,250-555-0101,All ages", "200 Harbour St,,All ages"))

          expect(service.reload.phone).to eq("250-555-0101")
          expect(service.address).to have_attributes(street_address: "100 Harbour St", city: "Victoria",
            coordinates: GeoPoint.new(lat: 48.43, lng: -123.37))
          expect(service.import_conflicts.pending.pluck(:field, :incoming_value)).to contain_exactly(
            ["phone", nil], ["address", {"street_address" => "200 Harbour St"}]
          )
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

          expect(service.reload).to have_attributes(phone: "250-555-0101", organization: renamed)
          expect(service.import_conflicts.pending.pluck(:field)).to eq(["phone"])
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

          travel_to(1.day.from_now) { described_class.new(source, confirmed_by: uploader).ingest(csv.sub("5 Cook St,,", "5 Cook St,250-555-0103,")) }

          expect(source.services.reload).to all(have_attributes(confirmed_by: uploader, confirmation_method: "upload"))
          expect(service.reload.confirmed_at).to be > 12.hours.from_now
        end

        # The details it vouched for are still the ones it shows.
        it "leaves the earlier confirmation on a service whose details wait for review" do
          uploader = User.create!(email: "uploader@example.com", password: "password123")
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service
          service.confirm!(by: User.create!(email: "checker@example.com", password: "password123"), method: "phone")

          described_class.new(source, confirmed_by: uploader).ingest(csv.sub("250-555-0101", "250-555-0199"))

          expect(service.reload).to have_attributes(phone: "250-555-0101", confirmation_method: "phone")
        end

        # Nobody has checked what a changed row now says.
        it "clears a service's confirmation when a detail it vouched for changes, and keeps it otherwise" do
          ingester.ingest(csv)
          checker = User.create!(email: "checker@example.com", password: "password123")
          service = source.documents.find_by!(external_id: "1").service
          service.confirm!(by: checker, method: "phone")

          described_class.new(source).ingest(csv)
          expect(service.reload.confirmation_method).to eq("phone")

          # The row reads differently, but names the same organization and details.
          described_class.new(source).ingest(csv.sub("Meals,Harbourside Society", "Meals,harbourside  SOCIETY"))
          expect(service.reload.confirmation_method).to eq("phone")

          # A detail the service had no value for is written straight away.
          bikes = source.documents.find_by!(external_id: "3").service
          bikes.confirm!(by: checker, method: "phone")
          described_class.new(source).ingest(csv.sub("5 Cook St,,", "5 Cook St,250-555-0103,"))
          expect(bikes.reload).to have_attributes(confirmed_at: nil, confirmed_by: nil, confirmation_method: nil)
        end

        it "writes straight away what the service had no value for" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "3").service

          described_class.new(source).ingest(csv.sub("5 Cook St,,", "5 Cook St,250-555-0103,"))

          expect(service.reload.phone).to eq("250-555-0103")
          expect(service.import_conflicts).to be_empty
        end

        it "replaces a waiting value when the row changes again" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service

          described_class.new(source).ingest(csv.sub("250-555-0101", "250-555-0199"))
          described_class.new(source).ingest(csv.sub("250-555-0101", "250-555-0177"))

          expect(service.import_conflicts.pending.pluck(:field, :incoming_value)).to eq([["phone", "250-555-0177"]])
        end

        it "drops a waiting value when the row goes back to what the service holds" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service

          described_class.new(source).ingest(csv.sub("250-555-0101", "250-555-0199"))
          described_class.new(source).ingest(csv)

          expect(service.import_conflicts.pending).to be_empty
        end

        it "holds a change of organization and a closed service reopening" do
          ingester.ingest(csv)
          service = source.documents.find_by!(external_id: "1").service
          service.update!(closed: true)

          described_class.new(source).ingest(csv.sub("1,Harbour Meals,Harbourside Society", "1,Harbour Meals,Our Place Society"))

          expect(service.reload).to have_attributes(closed: true, organization: have_attributes(name: "Harbourside Society"))
          expect(service.import_conflicts.pending.pluck(:field, :incoming_value)).to contain_exactly(
            ["organization", "Our Place Society"], ["closed", false]
          )
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
