require "rails_helper"
require "pdf/reader"

RSpec.describe FlyerPdf do
  def resource(title: "Meal program", **metadata)
    Document.new(title: title, content: title, metadata: metadata, source: Source.new(name: "Guide", source_type: "api"))
  end

  def reader_for(resources)
    section = CategorySearch::Section.new(category: Category.new(name: "Food"), resources: resources)
    bytes = described_class.new(sections: [section], printed_at: Time.zone.parse("2026-10-21 12:00:00")).render
    expect(bytes).to start_with("%PDF-")
    PDF::Reader.new(StringIO.new(bytes))
  end

  # Reads the generated PDF's actual text. Whitespace is squeezed because lines wrap
  # wherever the page width falls.
  describe "with a place to measure distances from" do
    def text_for(resources, origin)
      section = CategorySearch::Section.new(category: Category.new(name: "Food"), resources: resources)
      bytes = described_class.new(sections: [section], origin: origin).render
      PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n").gsub(/\s+/, " ")
    end

    let(:located) { FlyerOrigin.new(label: "919 Pandora Ave", point: GeoPoint.new(lat: 48.42, lng: -123.36)) }

    it "prints the distance on each card that has a known location" do
      text = text_for([resource(title: "Known", lat: 48.43, lng: -123.36), resource(title: "Unknown")], located)

      expect(text).to include("Distance: 1.1 km, about 13 min walk (straight-line)")
      expect(text.scan("Distance:").size).to eq(1)
    end

    it "says what the distances are measured from and that they're estimates" do
      text = text_for([resource(lat: 48.43, lng: -123.36)], located)

      expect(text).to include("Distances are from 919 Pandora Ave", "real routes may take longer")
    end

    it "explains missing distances when the geocoder was down" do
      unavailable = FlyerOrigin.new(label: "919 Pandora Ave", point: nil)
      text = text_for([resource(lat: 48.43, lng: -123.36)], unavailable)

      expect(text).to include("Distances aren't shown because we couldn't look up 919 Pandora Ave")
      expect(text).not_to include("Distance:")
    end

    it "prints no distances or note when no place was entered" do
      text = text_for([resource(lat: 48.43, lng: -123.36)], nil)

      expect(text).not_to include("Distance")
    end

    it "only prints the note on the first page" do
      resources = (1..24).map { |number| resource(title: "Resource #{number}", lat: 48.43, lng: -123.36, notes: "Details. " * 60) }
      section = CategorySearch::Section.new(category: Category.new(name: "Food"), resources: resources)
      reader = PDF::Reader.new(StringIO.new(described_class.new(sections: [section], origin: located).render))

      expect(reader.page_count).to be > 1
      expect(reader.pages.first.text.gsub(/\s+/, " ")).to include("Distances are from")
      expect(reader.pages.last.text).not_to include("Distances are from")
    end
  end

  it "creates a real readable PDF with the print date and missing fields omitted" do
    reader = reader_for([resource(description: "Meals", notes: "Bring a bag", intake_info: "Walk in")])
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

  it "prints differently sized cards alphabetically across aligned rows" do
    titles = %w[Alpha Bravo Charlie Delta]
    resources = titles.zip([1, 12, 3, 8]).map { |title, lines|
      resource(title: title, notes: ("Details for #{title}. " * lines))
    }
    section = CategorySearch::Section.new(category: Category.new(name: "Food"), resources: resources)
    renderer = described_class.new(sections: [section])
    placements = []
    allow(renderer).to receive(:draw_card).and_wrap_original do |draw, entry, x, top, width|
      placements << {title: entry.title, page: renderer.instance_variable_get(:@pdf).page_number,
                     x: x, top: top, width: width}
      draw.call(entry, x, top, width)
    end

    reader = PDF::Reader.new(StringIO.new(renderer.render))

    expect(reader.page_count).to eq(1)
    expect(placements.map { |placement| placement[:title] }).to eq(titles)
    expect(placements.map { |placement| placement[:page] }).to eq([1, 1, 1, 1])
    expect(placements[0][:top]).to eq(placements[1][:top])
    expect(placements[2][:top]).to eq(placements[3][:top])
    expect(placements[0][:top]).to be > placements[2][:top]
    expect(placements.map { |placement| placement[:x] }).to eq([0, renderer.instance_variable_get(:@column_width) + described_class::GUTTER] * 2)
    first_mentions = titles.map { |title| reader.pages.first.text.index(title) }
    expect(first_mentions).to all(be_present)
    expect(first_mentions).to eq(first_mentions.sort)
  end

  it "keeps the title sequence while continuing a category across pages" do
    titles = (1..24).map { |number| "Resource #{number.to_s.rjust(2, "0")}" }
    resources = titles.each_with_index.map { |title, index|
      resource(title: title, notes: "Opening hours and details. " * (index.even? ? 20 : 80))
    }
    section = CategorySearch::Section.new(category: Category.new(name: "Food"), resources: resources)
    renderer = described_class.new(sections: [section])
    printed_titles = []
    allow(renderer).to receive(:draw_card).and_wrap_original do |draw, entry, x, top, width|
      printed_titles << entry.title
      draw.call(entry, x, top, width)
    end

    reader = PDF::Reader.new(StringIO.new(renderer.render))

    expect(reader.page_count).to be > 1
    expect(printed_titles).to eq(titles)
    text = reader.pages.map(&:text).join("\n")
    first_mentions = titles.map { |title| text.index(title) }
    expect(first_mentions).to all(be_present)
    expect(first_mentions).to eq(first_mentions.sort)
  end

  it "starts a new page instead of skipping a tall earlier card" do
    sections = [
      CategorySearch::Section.new(category: Category.new(name: "Food"),
        resources: [resource(title: "Intro")]),
      CategorySearch::Section.new(category: Category.new(name: "Health"),
        resources: [resource(title: "Alpha"), resource(title: "Beta")])
    ]
    renderer = described_class.new(sections: sections)
    heights = {"Intro" => 430, "Alpha" => 300, "Beta" => 40}
    allow(renderer).to receive(:measurement) do |entry, _width|
      described_class::Measure.new(height: heights.fetch(entry.title), header_height: 0, row_heights: [])
    end
    printed_titles = []
    allow(renderer).to receive(:draw_card) { |entry, _x, _top, _width| printed_titles << entry.title }

    renderer.render

    expect(printed_titles).to eq(%w[Intro Alpha Beta])
  end

  it "continues an oversized field across pages without dropping its text" do
    words = (1..2400).map { |i| "step#{i.to_s.rjust(5, "0")}" }
    reader = reader_for([resource(notes: words.join(" "), intake_info: "Walk in")])
    text = reader.pages.map(&:text).join("\n")

    expect(reader.page_count).to be > 1
    expect(text).to include("continued")
    expect(text.scan(/step\d{5}/)).to eq(words)
    expect(reader.pages.last.text).to include("Intake:", "Walk in")
  end

  it "retains a very long resource name in the card body" do
    title = "Long resource " * 90 + "END_OF_RESOURCE_NAME"
    text = reader_for([resource(title: title, notes: "Saved notes")]).pages.map(&:text).join("\n")

    expect(text).to include("Resource name:", "END_OF_RESOURCE_NAME", "Saved notes")
  end

  it "does not label the first appearance of a new category as continued" do
    sections = [
      CategorySearch::Section.new(category: Category.new(name: "Food"),
        resources: [resource(notes: "Food details " * 400)]),
      CategorySearch::Section.new(category: Category.new(name: "Health"),
        resources: [resource(title: "Clinic", notes: "Clinic details " * 700)])
    ]
    bytes = described_class.new(sections: sections).render
    text = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n")

    expect(text.scan(/^Health(?: continued)?$/).first).to eq("Health")
  end
end
