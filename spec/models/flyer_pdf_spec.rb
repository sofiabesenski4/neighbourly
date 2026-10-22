require "rails_helper"
require "pdf/reader"

RSpec.describe FlyerPdf do
  def resource(title: "Meal program", **metadata)
    Document.new(title: title, content: title, metadata: metadata, source: Source.new(name: "Guide", source_type: "api"))
  end

  def reader_for(resources)
    section = ResourceCategorySearch::Section.new(category: ResourceCategory.all.first, resources: resources)
    bytes = described_class.new(sections: [section], printed_at: Time.zone.parse("2026-10-21 12:00:00")).render
    expect(bytes).to start_with("%PDF-")
    PDF::Reader.new(StringIO.new(bytes))
  end

  it "creates a real readable PDF with the print date and missing fields omitted" do
    reader = reader_for([resource(categories: ["Meals"], notes: "Bring a bag", intake_info: "Walk in")])
    text = reader.pages.map(&:text).join("\n")

    expect(text).to include("Meal program", "Services:", "Notes:", "Bring a bag", "Intake:", "Walk in", "2026-10-21")
    expect(text).not_to include("Hours:", "Last updated:", "Last checked:", "Information source:", "Not provided")
  end

  it "embeds Unicode fonts and preserves non ASCII resource text" do
    text = reader_for([resource(title: "Café — Привет", notes: "Children’s meals")]).pages.map(&:text).join("\n")

    expect(text).to include("Café", "Привет", "Children’s meals")
  end

  it "keeps the body size and uses full width for a final single card" do
    reader = reader_for([resource(notes: "A short note")])
    content = reader.pages.first.raw_content

    expect(content).to match(/11\.5\s+Tf/)
    widths = content.scan(/[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+[-\d.]+\s+re/).flatten.map(&:to_f)
    expect(widths.any? { |width| (width - 525.6).abs < 0.1 }).to be(true)
  end

  it "continues an oversized field across pages without dropping its text" do
    words = (1..2400).map { |i| "step#{i.to_s.rjust(5, "0")}" }
    reader = reader_for([resource(notes: words.join(" "))])
    text = reader.pages.map(&:text).join("\n")

    expect(reader.page_count).to be > 1
    expect(text).to include("continued")
    expect(text.scan(/step\d{5}/)).to eq(words)
  end

  it "retains a very long resource name in the card body" do
    title = "Long resource " * 90 + "END_OF_RESOURCE_NAME"
    text = reader_for([resource(title: title, notes: "Saved notes")]).pages.map(&:text).join("\n")

    expect(text).to include("Resource name:", "END_OF_RESOURCE_NAME", "Saved notes")
  end

  it "does not label the first appearance of a new category as continued" do
    sections = [
      ResourceCategorySearch::Section.new(category: ResourceCategory.all.first,
        resources: [resource(notes: "Food details " * 400)]),
      ResourceCategorySearch::Section.new(category: ResourceCategory.with_keys(["health"]).first,
        resources: [resource(title: "Clinic", notes: "Clinic details " * 700)])
    ]
    bytes = described_class.new(sections: sections).render
    text = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n")

    expect(text.scan(/^Health(?: continued)?$/).first).to eq("Health")
  end
end
