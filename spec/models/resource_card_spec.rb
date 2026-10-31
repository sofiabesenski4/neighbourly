require "rails_helper"

RSpec.describe ResourceCard do
  let(:source) { Source.new(name: "Guide", source_type: "api") }

  def card(metadata: {}, content: "Saved resource", title: "Meal program")
    described_class.new(Document.new(title: title, content: content, metadata: metadata, source: source))
  end

  it "omits complete fields whose values are missing" do
    expect(card.fields).to be_empty
    expect(card(metadata: {notes: " ", hours: nil, phone: [], email: ""}).fields).to be_empty
  end

  it "uses the agreed labels, puts Intake after Notes, and prints only provided dates" do
    fields = card(metadata: {categories: ["Meals"], address: "123 Main St", city: "Victoria",
                             hours: "Noon", notes: "Call ahead", intake_info: "Walk in", last_updated_at: "2026-10-15"}).fields

    expect(fields.map { |field| field[:label] }).to eq(["Services", "Address", "Hours", "Notes", "Intake", "Last updated"])
    expect(fields.find { |field| field[:label] == "Address" }[:value]).to eq("123 Main St, Victoria")
    expect(fields.map { |field| field[:label] }).not_to include("Last checked", "Information source")
  end

  it "reads multiline Notes and Intake from an older import's saved content" do
    fields = card(content: "Place\nCity: Victoria\nNotes: First line\nSecond line\nIntake: Call first").fields

    expect(fields).to include({label: "Notes", value: "First line\nSecond line"}, {label: "Intake", value: "Call first"})
  end

  it "labels the description Services and uses category labels when no description is saved" do
    expect(card(metadata: {description: "Free hot meals", categories: ["Food support"]}).fields)
      .to include({label: "Services", value: "Free hot meals"})
    expect(card(metadata: {categories: ["Food support"]}).fields)
      .to include({label: "Services", value: "Food support"})
  end

  it "prefers metadata over old content and puts separate phone numbers on separate lines" do
    fields = card(metadata: {notes: "Updated note", phone: ["250-555-0100", "250-555-0101"]}, content: "Place\nNotes: Old note").fields

    expect(fields).to include({label: "Notes", value: "Updated note"}, {label: "Phone", value: "250-555-0100\n250-555-0101"})
  end

  it "preserves zero and false rather than treating them as missing" do
    expect(card(metadata: {notes: false, age_range: {min: 0, max: 18}}).fields)
      .to include({label: "Notes", value: "false"}, {label: "Ages served", value: "0-18"})
  end

  it "does not expose arbitrary metadata, embeddings, or administrative fields" do
    data = card(metadata: {notes: "Public note", private_email: "secret@example.org", internal_review: "Hidden"}).as_json

    expect(data.keys).to eq([:id, :title, :fields])
    expect(data.to_json).not_to include("secret@example.org", "Hidden", "embedding")
  end

  it "uses a real supplied source URL without inventing one" do
    source.url = "https://example.org/guide"
    expect(card.fields).to include({label: "Information source", value: source.url})
  end
end
