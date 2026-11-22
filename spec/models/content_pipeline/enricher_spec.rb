require "rails_helper"

# Enrichment reads a service's own details and fills in only what it left
# blank. It never touches the row the service was read from.
RSpec.describe ContentPipeline::Enricher do
  include ActiveJob::TestHelper

  let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv", enrich_documents: true) }
  let(:document) do
    source.documents.create!(title: "Harbour Meals", content: "Program Name: Harbour Meals\nAddress: 100 Harbour St",
      external_id: "1", metadata: {"Program Name" => "Harbour Meals", "Address" => "100 Harbour St"})
  end
  let(:service) do
    source.services.create!(name: "Harbour Meals", document: document, enrichment_requested: true,
      description: "Hot lunches.", additional_details: {"Notes" => "Bring a bowl"},
      address_attributes: {street_address: "100 Harbour St"})
  end
  let(:answer) do
    {name: "Harbour Community Meals", summary: "Harbour Meals serves free hot lunches on weekdays.",
     categories: ["Meals", "food banks", "Astrology"], street_address: "1 Other St", city: "Victoria",
     province: "BC", postal_code: "", hours: "Weekdays noon to 1pm", phone: "250-555-0100", email: "",
     website: "harbourmeals.org", organization: "Harbourside Society", eligibility: "Anyone",
     ages: "", languages: "English, French", intake: "Walk in", cost: "Free"}
  end
  let(:reply) { answer.to_json }
  let(:chat) { instance_double(RubyLLM::Chat) }

  before do
    Category.create!(name: "Meals")
    Category.create!(name: "Food Banks")
    Category.create!(name: "Shelters")
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.25))
    allow(RubyLLM).to receive(:chat).and_return(chat)
    allow(chat).to receive_messages(with_instructions: chat, with_schema: chat)
    allow(chat).to receive(:ask) { instance_double(RubyLLM::Message, content: reply) }
  end

  describe "a confirmation" do
    let(:uploader) { User.create!(email: "uploader@example.com", password: "password123") }

    it "is renewed when the blanks are filled in, still by whoever confirmed it and how" do
      service.confirm!(by: uploader, method: "upload")

      travel_to(1.day.from_now) { described_class.new(service).enrich! }

      expect(service.reload).to have_attributes(hours: "Weekdays noon to 1pm", confirmed_by: uploader, confirmation_method: "upload")
      expect(service.confirmed_at).to be_within(1.second).of(service.enriched_at)
      expect(service.confirmed_at).to be > 12.hours.from_now
    end

    it "isn't made up for a service nobody confirmed" do
      described_class.new(service).enrich!

      expect(service.reload.confirmed_at).to be_nil
    end
  end

  it "writes the model's description, embeds it, and marks the service enriched" do
    described_class.new(service).enrich!

    expect(service.reload).to have_attributes(
      enriched_description: "Harbour Meals serves free hot lunches on weekdays.", enriched_at: be_present
    )
    expect(service.embedding.first).to eq(0.25)
    expect(ContentPipeline::Embedder).to have_received(:embed).with("Harbour Meals serves free hot lunches on weekdays.").once
  end

  it "fills in only the fields the service left blank" do
    described_class.new(service).enrich!

    expect(service.reload).to have_attributes(
      name: "Harbour Meals", description: "Hot lunches.", hours: "Weekdays noon to 1pm", phone: "250-555-0100",
      email: nil, website: "https://harbourmeals.org"
    )
    expect(service.address).to have_attributes(street_address: "100 Harbour St", city: "Victoria", province: "BC", postal_code: nil)
  end

  it "names a service only when it has no name" do
    service.update_columns(name: nil)

    described_class.new(service).enrich!

    expect(service.reload.name).to eq("Harbour Community Meals")
  end

  it "adds other facts to additional details, keeping what the service already has" do
    service.update!(additional_details: {"Notes" => "Bring a bowl", "Age Range" => "19+"})

    described_class.new(service).enrich!

    expect(service.reload.additional_details).to eq(
      "Notes" => "Bring a bowl", "Age Range" => "19+", "eligibility" => "Anyone",
      "languages" => "English, French", "intake" => "Walk in", "cost" => "Free"
    )
  end

  it "doesn't add a fact the service already has under another name" do
    service.update!(additional_details: {"Gender" => "Women", "Intake Info" => "Call first"})

    described_class.new(service).enrich!

    expect(service.reload.additional_details.keys).not_to include("eligibility", "intake")
  end

  it "assigns only categories that exist, matching names without regard to case, when it has none" do
    described_class.new(service).enrich!

    expect(service.reload.category_names).to eq(["Food Banks", "Meals"])
  end

  it "keeps the categories a service already has" do
    service.categories = [Category.find_by!(name: "Shelters")]

    described_class.new(service).enrich!

    expect(service.reload.category_names).to eq(["Shelters"])
  end

  it "links the organization the model found when the service has none" do
    described_class.new(service).enrich!

    expect(service.reload.organization).to have_attributes(name: "Harbourside Society", source: source)
  end

  it "keeps the organization the service has" do
    ours = Organization.create!(name: "Our Place Society")
    service.update!(organization: ours)

    described_class.new(service).enrich!

    expect(service.reload.organization).to eq(ours)
  end

  it "never changes the row the service was read from" do
    service

    expect { described_class.new(service).enrich! }.not_to(change { document.reload.attributes })
  end

  it "sends the service's details and the category list, constrained by a schema" do
    service.update!(organization: Organization.create!(name: "Our Place Society"))

    described_class.new(service).enrich!

    expect(chat).to have_received(:ask).with(
      %(Categories: ["Food Banks","Meals","Shelters"]\nService: {"name":"Harbour Meals","description":"Hot lunches.",) +
      %("address":{"street_address":"100 Harbour St"},"organization":"Our Place Society","additional_details":{"Notes":"Bring a bowl"}})
    )
    expect(chat).to have_received(:with_schema).with(
      hash_including(schema: hash_including(properties: hash_including("categories" => {type: "array", items: {type: "string", enum: ["Food Banks", "Meals", "Shelters"]}})))
    )
  end

  it "asks for a description based mostly on the service's own description" do
    described_class.new(service).enrich!

    expect(chat).to have_received(:with_instructions).with(/Base it mostly on the service's own description/)
  end

  it "uses ENRICHMENT_MODEL when set" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ENRICHMENT_MODEL").and_return("gpt-4.1-mini")

    described_class.new(service).enrich!

    expect(RubyLLM).to have_received(:chat).with(model: "gpt-4.1-mini")
  end

  describe "its address" do
    it "queues the lookup once the service has waited for enrichment" do
      service

      expect { described_class.new(service).enrich! }.to have_enqueued_job(GeocodeAddressJob).with(service.address).once
    end

    it "builds an address when the service had none" do
      service.address.destroy!
      service.reload

      described_class.new(service).enrich!

      expect(service.reload.address).to have_attributes(street_address: "1 Other St", city: "Victoria")
    end

    it "keeps coordinates the import gave when it fills in a blank city or province" do
      service.address.update_columns(lat: 48.43, lng: -123.37)
      answer[:province] = "Alberta"

      described_class.new(service).enrich!

      expect(service.reload.address).to have_attributes(city: "Victoria", province: "Alberta", lat: 48.43, lng: -123.37)
    end

    it "doesn't look the address up again when its coordinates are known and it didn't move" do
      service.address.update_columns(lat: 48.43, lng: -123.37)
      answer.merge!(city: "", province: "")

      expect { described_class.new(service).enrich! }.not_to have_enqueued_job(GeocodeAddressJob)
    end
  end

  it "drops a website that can't be made a web address" do
    answer[:website] = "call us"

    described_class.new(service).enrich!

    expect(service.reload.website).to be_nil
  end

  it "reads JSON wrapped in a code fence" do
    reply.replace("Here you go:\n```json\n{\"name\": \"Harbour Meals\", \"summary\": \"Lunches.\", \"categories\": []}\n```")

    described_class.new(service).enrich!

    expect(service.reload.enriched_description).to eq("Lunches.")
  end

  it "finds the JSON object after prose that holds braces of its own" do
    reply.replace("Fields used: {name}. Result:\n{\"name\": \"Harbour Meals\", \"summary\": \"Lunches.\", \"categories\": []}\nDone {ok}.")

    described_class.new(service).enrich!

    expect(service.reload.enriched_description).to eq("Lunches.")
  end

  it "treats a field that isn't text as missing" do
    reply.replace({name: ["Harbour"], summary: "Lunches.", categories: [], hours: 12}.to_json)

    described_class.new(service).enrich!

    expect(service.reload).to have_attributes(name: "Harbour Meals", hours: nil, enriched_description: "Lunches.")
  end

  it "names a nameless import by its row's title when the model gives no name" do
    service.update_columns(name: nil)
    answer[:name] = ""

    described_class.new(service).enrich!

    expect(service.reload.name).to eq("Harbour Meals")
  end

  it "can't use a reply that doesn't name a service added on the site with no name" do
    added = Source.form_entry_source.services.create!(enrichment_requested: true, description: "Lunches.")
    answer[:name] = ""

    expect { described_class.new(added).enrich! }.to raise_error(described_class::InvalidResponse, /no name/)
    expect(added.reload).to be_awaiting_enrichment
  end

  it "raises InvalidResponse when the summary is not text" do
    reply.replace({name: "Harbour Meals", summary: {text: "Lunches."}, categories: []}.to_json)

    expect { described_class.new(service).enrich! }.to raise_error(described_class::InvalidResponse, /no summary/)
  end

  it "raises InvalidResponse and leaves the service alone when the reply is not JSON" do
    reply.replace("Sorry, I can't help.")

    expect { described_class.new(service).enrich! }.to raise_error(described_class::InvalidResponse)
    expect(service.reload.enriched_at).to be_nil
  end

  it "raises the embedding service's error and leaves the service alone when embedding fails" do
    service
    allow(ContentPipeline::Embedder).to receive(:embed).and_raise(RubyLLM::RateLimitError, "slow down")

    expect { described_class.new(service).enrich! }.to raise_error(RubyLLM::RateLimitError)
    expect(service.reload.enriched_at).to be_nil
  end

  describe "while the model is answering" do
    it "saves nothing when another run enriched the service" do
      allow(chat).to receive(:ask) do
        Service.where(id: service.id).update_all(enriched_at: 1.minute.ago, enriched_description: "Earlier.")
        instance_double(RubyLLM::Message, content: reply)
      end

      expect { expect(described_class.new(service).enrich!).to be(false) }.not_to have_enqueued_job(EnrichServiceJob)
      expect(service.reload.enriched_description).to eq("Earlier.")
    end

    # The answer fits the old details, so a fresh run is queued for the new ones.
    it "saves nothing, and asks again, when the service changed" do
      allow(chat).to receive(:ask) do
        Service.where(id: service.id).update_all(hours: "Daily")
        instance_double(RubyLLM::Message, content: reply)
      end

      expect { expect(described_class.new(service).enrich!).to be(false) }.to have_enqueued_job(EnrichServiceJob).with(service)
      expect(service.reload).to have_attributes(hours: "Daily", enriched_at: nil)
    end

    it "gives up quietly when the service was deleted" do
      allow(chat).to receive(:ask) do
        Service.where(id: service.id).delete_all
        instance_double(RubyLLM::Message, content: reply)
      end

      expect(described_class.new(service).enrich!).to be(false)
    end
  end
end
