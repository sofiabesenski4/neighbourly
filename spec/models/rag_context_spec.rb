require "rails_helper"

RSpec.describe RagContext do
  let(:fake_vector) { Array.new(1536, 0.0).tap { |v| v[0] = 1.0 } }
  let(:rag_context) { described_class.new(limit: 3) }

  let(:source) { Source.create!(name: "BC 211 Shelters", url: "https://example.com/api", source_type: "csv") }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
  end

  describe "#augment" do
    context "when relevant documents exist" do
      before do
        source.documents.create!(
          content: "Test Shelter\nCity: Vancouver\nPhone: 604-555-1234",
          title: "Test Shelter",
          external_id: "1",
          embedding: fake_vector
        )
      end

      it "returns reference instructions separately from the user's question" do
        result = rag_context.augment("Where can I find shelter?")

        expect(result.instructions).to include("REFERENCE DOCUMENTS")
        expect(result.instructions).to include("Test Shelter")
        expect(result.instructions).to include("City: Vancouver")
        expect(result.instructions).to include("Source: BC 211 Shelters")
        expect(result.instructions).to include("[ref:#{source.documents.first.id}]")
        expect(result.instructions).not_to include("https://example.com/api")
        expect(result.instructions).not_to include("Where can I find shelter?")
      end

      it "returns the matched documents" do
        result = rag_context.augment("Where can I find shelter?")

        expect(result.documents.length).to eq(1)
        expect(result.documents.first.title).to eq("Test Shelter")
      end

      it "embeds the user's question to find relevant documents" do
        rag_context.augment("Where can I find shelter?")
        expect(ContentPipeline::Embedder).to have_received(:embed).with("Where can I find shelter?")
      end

      it "uses stable document IDs rather than retrieval positions" do
        source.documents.create!(
          content: "Another Shelter\nCity: Victoria",
          title: "Another Shelter",
          external_id: "2",
          embedding: fake_vector
        )

        result = rag_context.augment("shelters?")
        result.documents.each do |document|
          expect(result.instructions).to include("[ref:#{document.id}]")
        end
        expect(result.documents.length).to eq(2)
      end

      it "asks for supported reference markers without guessing source URLs" do
        instructions = rag_context.augment("shelters?").instructions.squish

        expect(instructions).to include("Cite a reference only when it supports the claim")
        expect(instructions).to include("Do not invent markers")
        expect(instructions).to include("Do not write, guess, or reconstruct reference URLs")
        expect(instructions).to include("do not comment on whether a URL is available")
      end

      it "limits answers to the reference documents without words of support" do
        instructions = rag_context.augment("shelters?").instructions.squish

        expect(instructions).to include("provide no general information based on your own knowledge")
        expect(instructions).to include("reaches out to the support team")
        expect(instructions).to include("DO NOT ADD ANY SORT OF HUMAN OPINION OR WORDS OF SUPPORT")
      end
    end

    context "when a matched row was read into a service" do
      let(:document) do
        source.documents.create!(content: "Test Shelter\nPhone: 604-555-0000", title: "Test Shelter row", embedding: fake_vector)
      end
      let!(:service) do
        source.services.create!(name: "Test Shelter", document: document, phone: "604-555-1234", hours: "Open 24 hours",
          organization: Organization.create!(name: "Shelter Society"), address_attributes: {street_address: "1 Main St", city: "Victoria"})
      end

      it "gives the service's current details instead of the row as imported" do
        service.update!(additional_details: {"Intake" => "Walk in", "Referral required" => false, "source_url" => "https://example.com/api/1"})

        instructions = rag_context.augment("Where can I find shelter?").instructions

        expect(instructions).to include("[ref:#{document.id}] Test Shelter (Source: BC 211 Shelters)")
        expect(instructions).to include("Offered by: Shelter Society", "Address: 1 Main St, Victoria", "Hours: Open 24 hours",
          "Phone: 604-555-1234", "Intake: Walk in", "Referral required: No")
        expect(instructions).not_to include("604-555-0000", "https://example.com/api")
      end

      # An admin cleared the number, so the one in the imported row is out of date.
      it "gives no phone number once the service's is removed" do
        service.update!(phone: nil)

        expect(rag_context.augment("Where can I find shelter?").instructions).not_to include("Phone:")
      end

      it "gives none of an imported row's phone numbers once the service's is removed" do
        ContentPipeline::Ingester.new(source).ingest("id,Name,Phone,Phone Number\n9,Harbour Meals,250-555-0111,250-555-0222\n")
        source.documents.find_by!(external_id: "9").service.update!(phone: nil)

        instructions = rag_context.augment("Where can I eat?").instructions

        expect(instructions).to include("Harbour Meals")
        expect(instructions).not_to include("250-555-0111", "250-555-0222")
      end

      it "gives the service's current hours over an imported column with the same name" do
        ContentPipeline::Ingester.new(source).ingest("id,Name,hours,Hours\n9,Harbour Meals,Mon-Fri,Weekends\n")
        service = source.documents.find_by!(external_id: "9").service
        expect(service.additional_details).to eq("Hours" => "Weekends")
        service.update!(hours: "Friday")

        instructions = rag_context.augment("When is it open?").instructions

        expect(instructions).to include("Hours: Friday")
        expect(instructions).not_to include("Weekends", "Mon-Fri")
      end

      it "gives no other imported column for a field once an admin changes or clears it" do
        ContentPipeline::Ingester.new(source).ingest(
          "id,Name,Hours,Schedule,Email,Email\n9,Harbour Meals,Mon-Fri,Weekdays only,a@example.org,b@example.org\n"
        )
        service = source.documents.find_by!(external_id: "9").service
        expect(service.additional_details).to eq("Schedule" => "Weekdays only", "Email (2)" => "b@example.org")
        service.update!(hours: nil, email: "new@example.org")

        instructions = rag_context.augment("When is it open?").instructions

        expect(instructions).to include("Email: new@example.org")
        expect(instructions).not_to include("Weekdays only", "Mon-Fri", "a@example.org", "b@example.org")
      end

      it "leaves out a closed service" do
        service.update!(closed: true)

        expect(rag_context.augment("Where can I find shelter?").documents).to be_empty
      end
    end

    # Enrichment embeds a service's AI description. Chat finds it by that.
    context "when a service was enriched" do
      let!(:added) do
        Source.form_entry_source.services.create!(name: "Breakfast Club", phone: "250-555-0199",
          enriched_description: "Breakfast Club serves free breakfast to anyone on weekdays.", embedding: fake_vector)
      end

      it "finds a service added on the site, which has no row, and cites it as a service" do
        result = rag_context.augment("Where can I get breakfast?")

        expect(result.services).to eq([added])
        expect(result.documents).to be_empty
        expect(result.instructions).to include("[ref:s#{added.id}] Breakfast Club (Source: Form Entries)",
          "Summary: Breakfast Club serves free breakfast", "Phone: 250-555-0199")
      end

      it "gives an imported service once, as the service, not again as its row" do
        row = source.documents.create!(title: "Lunch row", content: "Lunch", embedding: fake_vector)
        lunch = source.services.create!(name: "Harbour Lunch", document: row, enriched_description: "Lunches.", embedding: fake_vector)

        result = rag_context.augment("lunch?")

        expect(result.services).to contain_exactly(added, lunch)
        expect(result.documents).to be_empty
        expect(result.instructions).not_to include("[ref:#{row.id}]")
      end

      it "finds a service whose enrichment lands between the two searches, once" do
        row = source.documents.create!(title: "Supper row", content: "Supper", embedding: fake_vector)
        supper = source.services.create!(name: "Harbour Supper", document: row)
        searches = 0
        enrich_before_second_search = lambda do |original|
          searches += 1
          supper.update_columns(enriched_description: "Suppers.", embedding: fake_vector) if searches == 2
          original.call
        end
        allow(Service).to receive(:visible).and_wrap_original(&enrich_before_second_search)
        allow(Document).to receive(:with_embeddings).and_wrap_original(&enrich_before_second_search)

        result = rag_context.augment("supper?")

        expect(result.services).to include(supper)
        expect(result.documents).not_to include(row)
      end

      it "still finds a row whose service hasn't been enriched yet" do
        row = source.documents.create!(title: "Dinner row", content: "Dinner", embedding: fake_vector)
        source.services.create!(name: "Harbour Dinner", document: row)

        expect(rag_context.augment("dinner?").documents).to eq([row])
      end

      it "leaves out closed services and ones a moderator removed" do
        added.update!(closed: true)
        row = source.documents.create!(title: "Removed row", content: "Removed", embedding: nil)
        row.reports.create!(reason: "out of date", status: "valid")
        source.services.create!(name: "Removed", document: row, enriched_description: "Gone.", embedding: fake_vector)

        expect(rag_context.augment("anything?").services).to be_empty
      end

      it "gives at most the limit, closest first, across services and rows" do
        far = Array.new(1536, 0.0).tap { |v| v[1] = 1.0 }
        3.times { |n| source.documents.create!(title: "Far #{n}", content: "Far", embedding: far) }
        source.documents.create!(title: "Close", content: "Close", embedding: fake_vector)

        result = rag_context.augment("breakfast")

        expect(result.services + result.documents).to have_attributes(size: 3)
        expect(result.services).to eq([added])
        expect(result.documents.first.title).to eq("Close")
      end
    end

    context "when no documents exist at all" do
      it "still limits answers to the reference documents" do
        result = rag_context.augment("Hello")
        instructions = result.instructions.squish

        expect(instructions).to include("provide no general information based on your own knowledge")
        expect(instructions).to include("No reference documents matched this question.")
        expect(result.documents).to be_empty
      end
    end
  end
end
