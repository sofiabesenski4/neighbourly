require "rails_helper"

RSpec.describe ContentPipeline::Enricher do
  let(:source) { Source.create!(name: "Drop-in Centres", source_type: "csv") }
  let(:metadata) { {"Program Name" => "Harbour Meals", "Address" => "100 Harbour St", "Phone" => nil} }
  let(:document) do
    source.documents.create!(title: "Harbour Meals", content: "Program Name: Harbour Meals\nAddress: 100 Harbour St",
      external_id: "1", metadata: metadata)
  end
  let(:reply) do
    {title: "Harbour Meals", summary: "Free hot lunches on weekdays.", categories: ["Meals", "food banks", "Astrology"]}.to_json
  end
  let(:chat) { instance_double(RubyLLM::Chat) }

  before do
    Category.create!(name: "Meals")
    Category.create!(name: "Food Banks")
    Category.create!(name: "Shelters")
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    allow(RubyLLM).to receive(:chat).and_return(chat)
    allow(chat).to receive_messages(with_instructions: chat, with_schema: chat)
    allow(chat).to receive(:ask) { instance_double(RubyLLM::Message, content: reply) }
  end

  it "puts the summary above the row's original lines" do
    described_class.new(document).enrich!

    expect(document.reload.content).to eq("Free hot lunches on weekdays.\n\nProgram Name: Harbour Meals\nAddress: 100 Harbour St")
  end

  it "re-embeds the document with its new content" do
    described_class.new(document).enrich!

    expect(ContentPipeline::Embedder).to have_received(:embed).with(/\AFree hot lunches/)
  end

  it "embeds the new content once and stores that embedding" do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.25))

    described_class.new(document).enrich!

    expect(ContentPipeline::Embedder).to have_received(:embed).with(/\AFree hot lunches/).once
    expect(document.reload.embedding.first).to eq(0.25)
  end

  it "raises the embedding service's error and leaves the document alone when embedding fails" do
    document
    allow(ContentPipeline::Embedder).to receive(:embed).and_raise(RubyLLM::RateLimitError, "slow down")

    expect { described_class.new(document).enrich! }.to raise_error(RubyLLM::RateLimitError)
    expect(document.reload.enriched_at).to be_nil
  end

  it "assigns only categories that exist, matching names without regard to case" do
    described_class.new(document).enrich!

    expect(document.reload.category_names).to eq(["Food Banks", "Meals"])
  end

  it "uses the model's title and marks the document enriched" do
    reply.replace({title: "Harbour Community Meals", summary: "Lunches.", categories: []}.to_json)

    freeze_time do
      described_class.new(document).enrich!

      expect(document.reload).to have_attributes(title: "Harbour Community Meals", enriched_at: Time.current)
    end
  end

  it "keeps the existing title when the model gives none" do
    reply.replace({title: " ", summary: "Lunches.", categories: []}.to_json)

    described_class.new(document).enrich!

    expect(document.reload.title).to eq("Harbour Meals")
  end

  it "sends the row and the category list, constrained by a schema" do
    described_class.new(document).enrich!

    expect(chat).to have_received(:ask).with(
      %(Categories: ["Food Banks","Meals","Shelters"]\nRow: {"Program Name":"Harbour Meals","Address":"100 Harbour St"})
    )
    expect(chat).to have_received(:with_schema).with(
      hash_including(schema: hash_including(properties: hash_including(categories: {type: "array", items: {type: "string", enum: ["Food Banks", "Meals", "Shelters"]}})))
    )
  end

  it "uses ENRICHMENT_MODEL when set" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ENRICHMENT_MODEL").and_return("gpt-4.1-mini")

    described_class.new(document).enrich!

    expect(RubyLLM).to have_received(:chat).with(model: "gpt-4.1-mini")
  end

  it "reads JSON wrapped in a code fence" do
    reply.replace("Here you go:\n```json\n{\"title\": \"Harbour Meals\", \"summary\": \"Lunches.\", \"categories\": []}\n```")

    described_class.new(document).enrich!

    expect(document.reload.content).to start_with("Lunches.\n\n")
  end

  it "finds the JSON object after prose that holds braces of its own" do
    reply.replace("Fields used: {Program Name}. Result:\n{\"title\": \"Harbour Meals\", \"summary\": \"Lunches.\", \"categories\": []}\nDone {ok}.")

    described_class.new(document).enrich!

    expect(document.reload.content).to start_with("Lunches.\n\n")
  end

  it "raises InvalidResponse when the summary is not text" do
    reply.replace({title: "Harbour Meals", summary: {text: "Lunches."}, categories: []}.to_json)

    expect { described_class.new(document).enrich! }.to raise_error(described_class::InvalidResponse, /no summary/)
  end

  it "keeps the existing title when the model's title is not text" do
    reply.replace({title: ["Harbour"], summary: "Lunches.", categories: []}.to_json)

    described_class.new(document).enrich!

    expect(document.reload.title).to eq("Harbour Meals")
  end

  it "saves nothing when another run enriched the row while the model was answering" do
    allow(chat).to receive(:ask) do
      Document.where(id: document.id).update_all(enriched_at: 1.minute.ago, content: "Earlier summary.")
      instance_double(RubyLLM::Message, content: reply)
    end

    expect(described_class.new(document).enrich!).to be(false)
    expect(document.reload.content).to eq("Earlier summary.")
  end

  it "keeps the resource out of search when its removal was accepted while the model was answering" do
    allow(chat).to receive(:ask) do
      document.reports.create!(reason: "out of date", status: "valid")
      Document.where(id: document.id).update_all(embedding: nil)
      instance_double(RubyLLM::Message, content: reply)
    end

    described_class.new(document).enrich!

    expect(document.reload).to have_attributes(embedding: nil, enriched_at: be_present)
    expect(document.content).to start_with("Free hot lunches on weekdays.")
  end

  it "raises InvalidResponse and leaves the document alone when the reply is not JSON" do
    reply.replace("I cannot help with that.")

    expect { described_class.new(document).enrich! }.to raise_error(described_class::InvalidResponse)
    expect(document.reload.enriched_at).to be_nil
  end

  it "raises InvalidResponse when the reply has no summary" do
    reply.replace({title: "Harbour Meals", summary: "", categories: []}.to_json)

    expect { described_class.new(document).enrich! }.to raise_error(described_class::InvalidResponse, /no summary/)
  end

  it "saves nothing when the row changed while the model was answering" do
    allow(chat).to receive(:ask) do
      Document.find(document.id).update!(metadata: metadata.merge("Phone" => "250-555-0100"))
      instance_double(RubyLLM::Message, content: reply)
    end

    expect(described_class.new(document).enrich!).to be(false)
    expect(document.reload).to have_attributes(enriched_at: nil, content: "Program Name: Harbour Meals\nAddress: 100 Harbour St")
  end

  it "saves the summary when geocoding added coordinates while the model was answering" do
    allow(chat).to receive(:ask) do
      Document.where(id: document.id).update_all(metadata: metadata.merge("lat" => 48.43, "lng" => -123.37))
      instance_double(RubyLLM::Message, content: reply)
    end

    described_class.new(document).enrich!

    expect(document.reload).to have_attributes(
      enriched_at: be_present, metadata: hash_including("lat" => 48.43, "lng" => -123.37)
    )
    expect(document.content).to start_with("Free hot lunches on weekdays.")
  end
end
