require "rails_helper"
require "pdf/reader"

# Draws onto a real Prawn document and reads the resulting PDF back, so these check what
# actually reaches the page rather than which methods got called.
RSpec.describe FlyerMapPage do
  let(:downtown) { described_class::DOWNTOWN }
  let(:near_downtown) { GeoPoint.new(lat: 48.4280, lng: -123.3640) }

  def item(number, title: "Resource #{number}", point: near_downtown)
    MapPinLayout::Item.new(number: number, title: title, point: point)
  end

  # The same page setup as FlyerPdf, including the font, which holds the ≈ and © characters.
  def document
    pdf = Prawn::Document.new(page_size: "LETTER", margin: FlyerPdf::MARGIN)
    fonts = Rails.root.join("app/assets/fonts/dejavu")
    pdf.font_families.update("ResourceSans" => {
      normal: fonts.join("DejaVuSans.ttf").to_s,
      bold: fonts.join("DejaVuSans-Bold.ttf").to_s
    })
    pdf.font("ResourceSans")
    pdf
  end

  def draw(items, **options)
    pdf = document
    described_class.new(pdf, items: items, **options).draw
    PDF::Reader.new(StringIO.new(pdf.render))
  end

  def text_of(reader)
    reader.pages.map(&:text).join("\n").gsub(/\s+/, " ")
  end

  def images_on(page)
    page.xobjects.values.count { |object| object.hash[:Subtype] == :Image }
  end

  it "draws real tiles, clipped to the map's frame" do
    page = draw([item(1)]).pages.first

    expect(images_on(page)).to be > 1
    expect(page.raw_content).to match(/[\d.]+ [\d.]+ [\d.]+ [\d.]+ re W n/)
  end

  # Pins must land where MapView says, which is where the tiles put that street. The text
  # is centred on the pin, so its position is compared with the frame's position on the page.
  it "places a pin's number at the resource's position on the map" do
    pdf = document
    top = pdf.cursor
    described_class.new(pdf, items: [item(7)]).draw
    run = PDF::Reader.new(StringIO.new(pdf.render)).pages.first.runs.find { |text_run| text_run.text == "7" }

    view = MapView.new(frame_width: pdf.bounds.width, frame_height: top - below_map_height(pdf),
      manifest: MapTileSet.default.view_manifest, centre: downtown, radius_km: described_class::RADIUS_KM)
    position = view.page_position(near_downtown)

    expect(run.x + run.width / 2).to be_within(1).of(FlyerPdf::MARGIN + position.x)
    expect(run.y).to be_within(4).of(FlyerPdf::MARGIN + below_map_height(pdf) + position.y)
  end

  # The space the scale and credit take under a map with no not-shown list.
  def below_map_height(pdf)
    page = described_class.new(pdf, items: [])
    described_class::GAP + described_class::SCALE_ROW_HEIGHT + page.send(:credit_height)
  end

  it "shares one pin between resources at the same spot" do
    runs = draw([item(3), item(7)]).pages.first.runs.map(&:text)

    expect(runs).to include("3, 7")
  end

  it "shows only numbers on pins, not names" do
    expect(text_of(draw([item(3, title: "Our Place")]))).not_to include("Our Place")
  end

  it "prints the credit and a scale bar matching the cards' walking pace" do
    text = text_of(draw([item(1)]))

    expect(text).to include("© OpenMapTiles © OpenStreetMap contributors", "Positron", "1 km ≈ 16 min walk")
  end

  it "lists resources with no coordinates rather than pinning them" do
    text = text_of(draw([item(1), item(2, title: "Cridge", point: nil)]))

    expect(text).to include("Not shown on map: 2. Cridge")
  end

  it "lists a resource with impossible coordinates as not shown" do
    text = text_of(draw([item(4, title: "Bad import", point: GeoPoint.new(lat: 999.0, lng: -123.36))]))

    expect(text).to include("Not shown on map: 4. Bad import")
  end

  it "prints nothing about missing resources when all have coordinates" do
    expect(text_of(draw([item(1)]))).not_to include("Not shown on map")
  end

  describe "resources off the map" do
    # About 4 km north and east of downtown, well outside a 1.3 km map.
    let(:far_north) { GeoPoint.new(lat: 48.4625, lng: -123.3656) }
    let(:far_east) { GeoPoint.new(lat: 48.4265, lng: -123.3100) }

    def frame_runs(reader)
      reader.pages.first.runs
    end

    it "prints an arrow label with the number and distance from the map's centre" do
      reader = draw([item(5, point: far_north)])

      expect(frame_runs(reader).map(&:text)).to include("5", "4.0 km")
      expect(text_of(reader)).not_to include("Not shown on map")
    end

    it "draws no arrow for a resource on the map" do
      texts = frame_runs(draw([item(5)])).map(&:text)

      expect(texts.grep(/\d km\z/)).to be_empty
    end

    it "keeps the label inside the frame" do
      pdf = document
      top = pdf.cursor
      described_class.new(pdf, items: [item(5, point: far_east)]).draw
      run = PDF::Reader.new(StringIO.new(pdf.render)).pages.first.runs.find { |text_run| text_run.text == "5" }

      expect(run.x).to be_between(FlyerPdf::MARGIN, FlyerPdf::MARGIN + pdf.bounds.width)
      expect(run.y).to be < FlyerPdf::MARGIN + top
    end

    it "merges resources in the same direction, showing the range of distances" do
      further = GeoPoint.new(lat: 48.5000, lng: -123.3656)
      texts = frame_runs(draw([item(5, point: far_north), item(9, point: further)])).map(&:text)

      expect(texts).to include("5, 9", "4.0–8.2 km")
    end

    # Reads the label rectangles the page would draw, because a covered label hides its numbers.
    it "merges further when labels would overlap, keeping every number" do
      ring = (0...40).map do |step|
        angle = step * 9 * Math::PI / 180
        item(step + 1, point: GeoPoint.new(lat: downtown.lat + 0.06 * Math.sin(angle), lng: downtown.lng + 0.09 * Math.cos(angle)))
      end
      pdf = document
      page = described_class.new(pdf, items: ring)
      view = page.send(:view_with_height, 640)
      layout = page.send(:layout_without_label_overlaps, view)

      expect(page.send(:markers_overlap?, layout.edge_markers, view)).to be(false)
      expect(layout.edge_markers.flat_map(&:numbers)).to match_array(1..40)
    end

    it "wraps a marker holding many numbers, keeping them all" do
      many = (1..60).map { |number| item(number, point: far_north) }
      text = text_of(draw(many))

      expect(text).to include("1, 2, 3", "59, 60")
    end
  end

  describe "the You are here marker" do
    let(:location) { GeoPoint.new(lat: 48.4300, lng: -123.3500) }

    def texts_on(reader)
      reader.pages.first.runs.map(&:text).join(" ")
    end

    it "marks a chosen location at the middle of the map" do
      pdf = document
      described_class.new(pdf, items: [item(1)], centre: location).draw
      run = PDF::Reader.new(StringIO.new(pdf.render)).pages.first.runs.find { |text_run| text_run.text.include?("You are here") }

      expect(run.x + run.width / 2).to be_within(1).of(FlyerPdf::MARGIN + pdf.bounds.width / 2)
    end

    it "shows no marker without a chosen location" do
      expect(texts_on(draw([item(1)]))).not_to include("You are here")
    end

    # The map falls back to downtown here, so the location isn't on the page.
    it "shows no marker for a location with no tiles" do
      vancouver = GeoPoint.new(lat: 49.2827, lng: -123.1207)

      expect(texts_on(draw([item(1)], centre: vancouver))).not_to include("You are here")
    end

    it "draws the marker before the pins, so it can't hide a pin at the same place" do
      page = described_class.new(document, items: [item(1, point: location)], centre: location)
      allow(page).to receive(:draw_you_are_here).and_call_original
      allow(page).to receive(:draw_pin).and_call_original

      page.draw

      expect(page).to have_received(:draw_you_are_here).ordered
      expect(page).to have_received(:draw_pin).ordered
    end
  end

  it "continues a very long not-shown list on another page, keeping every name" do
    items = (1..600).map { |number| item(number, title: "Resource name #{number}", point: nil) }
    reader = draw(items)

    expect(reader.page_count).to be > 1
    expect(text_of(reader)).to include("600. Resource name 600")
  end

  it "keeps the map at a readable height when the not-shown list is long" do
    items = (1..600).map { |number| item(number, point: nil) }
    pdf = document
    page = described_class.new(pdf, items: items)
    allow(page).to receive(:build_view).and_call_original

    page.draw

    expect(page).to have_received(:build_view).with(downtown, described_class::MIN_MAP_HEIGHT)
  end

  it "centres on the given location" do
    elsewhere = GeoPoint.new(lat: 48.4600, lng: -123.3100)
    pdf = document
    page = described_class.new(pdf, items: [item(1)], centre: elsewhere)
    allow(page).to receive(:build_view).and_call_original

    page.draw

    expect(page).to have_received(:build_view).with(elsewhere, anything).at_least(:once)
    expect(page).not_to have_received(:build_view).with(downtown, anything)
  end

  it "shows downtown rather than an empty box for a location with no tiles" do
    vancouver = GeoPoint.new(lat: 49.2827, lng: -123.1207)
    page = draw([item(1)], centre: vancouver).pages.first

    expect(images_on(page)).to be > 1
    expect(page.runs.map(&:text)).to include("1")
  end

  it "still prints when a tile file is missing" do
    tile_set = instance_double(MapTileSet, view_manifest: MapTileSet.default.view_manifest, path_for: nil,
      attribution: "Credit", style_credit: "Style")
    page = draw([item(1)], tile_set: tile_set).pages.first

    expect(images_on(page)).to eq(0)
    expect(page.runs.map(&:text)).to include("1")
  end

  it "uses a zoom where street names are printed" do
    view = MapView.new(frame_width: 525.6, frame_height: 640, manifest: MapTileSet.default.view_manifest,
      centre: downtown, radius_km: described_class::RADIUS_KM)

    expect(view.zoom).to eq(15)
  end
end
