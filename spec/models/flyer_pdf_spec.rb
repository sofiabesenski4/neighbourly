require "rails_helper"
require "pdf/reader"

RSpec.describe FlyerPdf do
  # Coordinates go on the address. Other details, like notes, are kept as an
  # import keeps its extra columns.
  def resource(title: "Meal program", id: nil, lat: nil, lng: nil, description: nil, **details)
    Service.new(id: id, name: title, description: description, additional_details: details,
      source: Source.new(name: "Guide", source_type: "csv")).tap do |service|
      service.build_address(lat: lat, lng: lng) if lat
    end
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

      expect(text).to include("Distance: 1.1 km straight-line, about 17 min walk")
      expect(text.scan("Distance:").size).to eq(1)
    end

    it "says what the distances are measured from and that they're estimates" do
      text = text_for([resource(lat: 48.43, lng: -123.36)], located)

      expect(text).to include("Distances are from 919 Pandora Ave", "some routes may take longer")
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

    it "only prints the note on the first resource page" do
      resources = (1..24).map { |number| resource(title: "Resource #{number}", lat: 48.43, lng: -123.36, notes: "Details. " * 60) }
      section = CategorySearch::Section.new(category: Category.new(name: "Food"), resources: resources)
      reader = PDF::Reader.new(StringIO.new(described_class.new(sections: [section], origin: located).render))

      expect(reader.page_count).to be > 4
      expect(reader.pages.fetch(2).text.gsub(/\s+/, " ")).to include("Distances are from")
      expect(reader.pages.fetch(3).text).not_to include("Distances are from")
    end
  end

  describe "numbering resources to match the map" do
    def section(name, resources)
      CategorySearch::Section.new(category: Category.new(name: name), resources: resources)
    end

    def text_of(sections)
      PDF::Reader.new(StringIO.new(described_class.new(sections: sections).render))
        .pages.map(&:text).join("\n").gsub(/\s+/, " ")
    end

    it "numbers card headers in print order across categories" do
      text = text_of([section("Food", [resource(title: "Alpha")]), section("Health", [resource(title: "Beta")])])

      expect(text).to include("1. Alpha", "2. Beta")
    end

    it "gives a resource in two categories the same number on both cards" do
      shared = resource(id: 7, title: "Shared")
      copy = resource(id: 7, title: "Shared")
      text = text_of([section("Food", [shared, resource(title: "Other")]), section("Health", [copy])])

      expect(text.scan("1. Shared").size).to be >= 2
      expect(text).to include("2. Other")
      expect(text).not_to include("3. ")
    end
  end

  it "prints Start Here, a linked Quick finder, the listings, then the map" do
    reader = reader_for([resource(lat: 48.4265, lng: -123.3656)])

    expect(reader.page_count).to eq(4)
    expect(reader.pages.drop(1).map { |page| page.text.gsub(/\s+/, "") }).to all(include("NEIGHBOURLYRESOURCEGUIDE"))
    expect(reader.pages.first.raw_content).to match(%r{/I\d+\s+Do})
    finder = reader.pages.fetch(1)
    expect(finder.text).to include("Quick finder", "Food", "Page 3", "My notes", "Page 2 of 4")
    expect(finder.text.scan(/Quick finder|Food|Made with Neighbourly|My notes/))
      .to eq(["Quick finder", "Food", "Made with Neighbourly", "My notes"])
    links = finder.attributes.fetch(:Annots).map { |annotation| reader.objects.deref(annotation) }
    expect(links).to include(a_hash_including(Subtype: :Link, Dest: "service-page-3"))
    expect(reader.pages.fetch(2).text).to include("Meal program", "Page 3")
    expect(reader.pages.last.text).to include("Map", "© OpenMapTiles © OpenStreetMap contributors", "Page 4")
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

  it "keeps the body size and rounds the full-width frame of a final single card" do
    section = CategorySearch::Section.new(category: Category.new(name: "Food"), resources: [resource(notes: "A short note")])
    renderer = described_class.new(sections: [section])
    pdf = renderer.instance_variable_get(:@pdf)
    allow(pdf).to receive(:stroke_rounded_rectangle).and_call_original

    reader = PDF::Reader.new(StringIO.new(renderer.render))
    content = reader.pages.fetch(2).raw_content

    expect(content).to match(/11\.5\s+Tf/)
    expect(pdf).to have_received(:stroke_rounded_rectangle).with(anything, be_within(0.1).of(525.6), anything, described_class::CARD_RADIUS)
  end

  it "repeats parent colours on category headings and keeps resource card borders black" do
    parents = 1.upto(7).map { |number| Category.create!(name: "Palette group #{number}") }
    child = Category.create!(name: "Palette child", parent: parents.first)
    sections = [parents.first, child, *parents.drop(1)].map do |category|
      CategorySearch::Section.new(category: category, resources: [resource(title: category.name)])
    end
    renderer = described_class.new(sections: sections)
    pdf = renderer.instance_variable_get(:@pdf)
    outlines = Hash.new { |by_radius, radius| by_radius[radius] = [] }
    palette = FlyerQuickFinder::PALETTE
    title_colours = []
    allow(pdf).to receive(:stroke_rounded_rectangle).and_wrap_original do |draw, corner, width, height, radius|
      outlines[radius] << pdf.stroke_color
      draw.call(corner, width, height, radius)
    end
    allow(pdf).to receive(:text_box).and_wrap_original do |draw, text, options = {}|
      title_colours << pdf.fill_color if options[:size] == described_class::SECTION_TITLE_SIZE
      draw.call(text, options)
    end

    renderer.render

    expected = [palette.first, *palette, palette.first, "000000"]
    expect(title_colours).to eq(expected.map { |colour| described_class::SECTION_TITLE_COLOURS.fetch(colour, colour) })
    expect(outlines.fetch(described_class::SECTION_MIN_HEIGHT / 2.0)).to eq(expected)
    expect(outlines.fetch(described_class::CARD_RADIUS)).to eq(["000000"] * sections.size)
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

    expect(reader.page_count).to eq(4) # the cover, the finder, the cards, then the map
    expect(placements.map { |placement| placement[:title] }).to eq(titles)
    expect(placements.map { |placement| placement[:page] }).to eq([3, 3, 3, 3])
    expect(placements[0][:top]).to eq(placements[1][:top])
    expect(placements[2][:top]).to eq(placements[3][:top])
    expect(placements[0][:top]).to be > placements[2][:top]
    expect(placements.map { |placement| placement[:x] }).to eq([0, renderer.instance_variable_get(:@column_width) + described_class::GUTTER] * 2)
    first_mentions = titles.map { |title| reader.pages.fetch(2).text.index(title) }
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

    expect(reader.page_count).to be > 4
    expect(reader.pages.fetch(1).text).to include("Pages 3–#{reader.page_count - 1}")
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

    expect(reader.page_count).to be > 4
    expect(reader.pages.fetch(1).text).to include("Pages 3–#{reader.page_count - 1}")
    expect(text).to include("continued")
    expect(text.scan(/step\d{5}/)).to eq(words)
    expect(reader.pages[-2].text).to include("Intake:", "Walk in")
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

    expect(text.lines.map(&:strip).grep(/\AHealth(?: continued)?\z/).first).to eq("Health")
  end
end
