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
