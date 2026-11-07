require "rails_helper"

# Covers choosing a zoom and scale, mapping GeoPoints to the page, listing tiles, and the
# inside-the-frame check. It uses a made-up manifest with realistic Victoria bounds, where
# zoom 16 covers only the urban core.
#
# Expected zooms are worked out by hand in the comments. At Victoria's latitude, one world
# pixel at zoom 16 is about 1.585 m, doubling with each lower zoom.
#
# Doesn't cover pins and edge markers (see map_pin_layout_spec.rb), drawing, or reading a
# real manifest.json or tile files, because those steps don't exist yet.
RSpec.describe MapView do
  let(:region) { {south: 48.28, west: -123.75, north: 48.72, east: -123.2} }
  let(:urban_core) { {south: 48.40, west: -123.40, north: 48.45, east: -123.33} }
  let(:manifest) do
    {min_zoom: 11, max_zoom: 16, zooms: (11..15).to_h { |zoom| [zoom, region] }.merge(16 => urban_core)}
  end
  let(:pandora) { GeoPoint.new(lat: 48.4271129, lng: -123.3577635) }
  let(:admirals) { GeoPoint.new(lat: 48.4284587, lng: -123.4174225) }

  def view_around(centre, radius_km, width: 525, height: 400, zooms: manifest)
    described_class.new(frame_width: width, frame_height: height, manifest: zooms, centre: centre, radius_km: radius_km)
  end

  # The GeoPoint a given distance away in a compass direction, using the standard formula
  # for travelling along a sphere. Written here so it's independent of the code under test.
  def travel(from, km, bearing_degrees)
    angle = km / GeoPoint::EARTH_RADIUS_KM
    bearing = bearing_degrees * Math::PI / 180
    lat = from.lat * Math::PI / 180
    new_lat = Math.asin(Math.sin(lat) * Math.cos(angle) + Math.cos(lat) * Math.sin(angle) * Math.cos(bearing))
    lng_change = Math.atan2(Math.sin(bearing) * Math.sin(angle) * Math.cos(lat),
      Math.cos(angle) - Math.sin(lat) * Math.sin(new_lat))

    GeoPoint.new(lat: new_lat * 180 / Math::PI, lng: from.lng + lng_change * 180 / Math::PI)
  end

  describe "choosing the zoom" do
    it "uses zoom 16 when a small area is inside the urban core" do
      # 800 m / 1.585 m = 505 world pixels tall. 400 / 505 = 0.79, a readable scale.
      view = view_around(pandora, 0.4)

      expect(view.zoom).to eq(16)
      expect(view.scale).to be_within(0.01).of(0.79)
      expect(view).to be_fully_covered
    end

    it "falls back to zoom 15 when zoom 16's coverage doesn't reach the area" do
      # Admirals Rd is west of the urban core. Zoom 16 would fit, but has no tiles there.
      view = view_around(admirals, 0.4)

      expect(view.zoom).to eq(15)
      expect(view).to be_fully_covered
    end

    it "falls back when the area is centred in the urban core but runs past its edge" do
      view = view_around(GeoPoint.new(lat: 48.4271, lng: -123.399), 0.4)

      expect(view.zoom).to eq(15)
      expect(view).to be_fully_covered
    end

    it "falls back past a missing zoom" do
      zooms = manifest.merge(zooms: manifest[:zooms].except(15))

      expect(view_around(admirals, 0.4, zooms: zooms).zoom).to eq(14)
    end

    it "ignores zooms the manifest's range excludes" do
      expect(view_around(pandora, 0.4, zooms: manifest.merge(max_zoom: 15)).zoom).to eq(15)
    end

    it "picks the most detailed zoom that fits at a readable scale" do
      # 4 km / 3.17 m at zoom 15 = 1262 world pixels. 400 / 1262 = 0.32, too small to read.
      # Zoom 14 doubles that to 0.63, which is readable.
      view = view_around(pandora, 2)

      expect(view.zoom).to eq(14)
      expect(view.scale).to be_within(0.01).of(0.634)
      expect(view.scale).to be_between(described_class::MIN_SCALE, described_class::MAX_SCALE)
    end

    it "takes the frame's tighter direction into account" do
      # In a tall frame the width limits the fit: 525 / 1262 = 0.42 at zoom 15, 0.83 at 14.
      view = view_around(pandora, 2, width: 525, height: 2000)

      expect(view.zoom).to eq(14)
      expect(view.scale).to be_within(0.02).of(0.83)
    end

    it "limits how far a very small radius is enlarged" do
      view = view_around(pandora, 0.01)

      expect(view.zoom).to eq(16)
      expect(view.scale).to eq(described_class::MAX_SCALE)
    end

    it "handles a radius of zero" do
      view = view_around(pandora, 0)

      expect(view.zoom).to eq(16)
      expect(view.scale).to eq(described_class::MAX_SCALE)
      expect(view.page_position(pandora).x).to be_within(1e-9).of(262.5)
    end

    it "shrinks below the readable scale when even the widest zoom can't otherwise fit" do
      view = view_around(pandora, 500)

      expect(view.zoom).to eq(11)
      expect(view.scale).to be < described_class::MIN_SCALE
      expect(view).not_to be_fully_covered
      expect(view.inside_frame?(view.page_position(travel(pandora, 500, 0)))).to be true
      expect(view.inside_frame?(view.page_position(travel(pandora, 500, 90)))).to be true
    end

    it "survives a radius that wraps the whole Earth" do
      view = view_around(pandora, 25_000)

      expect(view.zoom).to eq(11)
      expect(view.scale).to be > 0
      expect(view.page_position(pandora).x).to be_within(1e-9).of(262.5)
      expect(view.tiles).not_to be_empty
    end

    it "accepts a manifest parsed from JSON, with string keys" do
      parsed = JSON.parse(manifest.to_json)

      expect(view_around(pandora, 0.4, zooms: parsed).zoom).to eq(16)
    end
  end

  describe "a centre whose area runs past the coverage" do
    # 48.30 is close to the region's south edge at 48.28, so a 5 km radius runs past it at
    # every zoom. 10 km / 25.4 m at zoom 12 = 394 pixels, for a scale of 1.02. Zoom 13
    # would halve that to 0.51, which is below the readable scale.
    let(:southern_point) { GeoPoint.new(lat: 48.30, lng: -123.40) }

    it "keeps the centre at the frame's middle and draws what exists" do
      view = view_around(southern_point, 5)

      expect(view.zoom).to eq(12)
      expect(view.scale).to be_within(0.02).of(1.02)
      expect(view).not_to be_fully_covered
      expect(view.page_position(southern_point).x).to be_within(1e-9).of(262.5)
      expect(view.page_position(southern_point).y).to be_within(1e-9).of(200)
      expect(view.centre).to eq(southern_point)
      expect(view.tiles).not_to be_empty
    end

    it "prefers the zoom showing the most of the area over a more detailed scrap" do
      # This 400 m radius fits at all three zooms, and none holds all of it. Pandora is on
      # zoom 16's south-west corner, so it holds about a quarter of the area. Zoom 15 holds
      # about half, and zoom 14 about three quarters.
      zooms = {min_zoom: 11, max_zoom: 16, zooms: {
        14 => {south: 48.4, west: -123.36, north: 48.5, east: -123.3},
        15 => {south: 48.4, west: -123.3577635, north: 48.5, east: -123.3},
        16 => {south: 48.4271129, west: -123.3577635, north: 48.5, east: -123.3}
      }}
      view = view_around(pandora, 0.4, zooms: zooms)

      expect(view.zoom).to eq(14)
      expect(view).not_to be_fully_covered
    end

    it "picks the most detailed zoom when several show the same share of the area" do
      partial = {south: 48.4, west: -123.3577635, north: 48.5, east: -123.3}
      zooms = {min_zoom: 11, max_zoom: 16, zooms: {14 => partial, 15 => partial, 16 => partial}}

      expect(view_around(pandora, 0.4, zooms: zooms).zoom).to eq(16)
    end

    it "doesn't fail when the centre is outside all coverage, and draws no tiles" do
      vancouver = GeoPoint.new(lat: 49.2827, lng: -123.1207)
      view = view_around(vancouver, 2)

      expect(view.zoom).to eq(14)
      expect(view).not_to be_fully_covered
      expect(view.tiles).to be_empty
      expect(view.page_position(vancouver).x).to be_within(1e-9).of(262.5)
    end
  end

  describe "an area-wide map from bounds" do
    let(:view) do
      described_class.new(frame_width: 525, frame_height: 650, manifest: manifest, bounds: region)
    end

    it "fits the whole area and picks the zoom by hand-worked scale" do
      # 0.55 degrees of longitude = 0.55 / 360 * 524288 = 801 world pixels at zoom 11.
      # 525 / 801 = 0.655, which is the tighter direction here.
      expect(view.zoom).to eq(11)
      expect(view.scale).to be_within(0.001).of(0.655)
      expect(view).to be_fully_covered
    end

    it "keeps all four corners in the frame" do
      [[48.28, -123.75], [48.28, -123.2], [48.72, -123.75], [48.72, -123.2]].each do |lat, lng|
        expect(view.inside_frame?(view.page_position(GeoPoint.new(lat: lat, lng: lng)))).to be true
      end
    end

    it "centres the bounds on the page, using the Mercator middle rather than the average latitude" do
      north = view.page_position(GeoPoint.new(lat: 48.72, lng: -123.5))
      south = view.page_position(GeoPoint.new(lat: 48.28, lng: -123.5))
      centre = view.page_position(view.centre)

      expect(north.y - 325).to be_within(1e-6).of(325 - south.y)
      expect(centre.x).to be_within(1e-6).of(262.5)
      expect(centre.y).to be_within(1e-6).of(325)
      expect(view.centre.lat).not_to be_within(1e-4).of(48.5)
    end

    it "accepts string-keyed bounds" do
      other = described_class.new(frame_width: 525, frame_height: 650, manifest: manifest, bounds: region.stringify_keys)

      expect(other.zoom).to eq(view.zoom)
    end

    it "draws what exists when the bounds run past all coverage" do
      wide = described_class.new(frame_width: 525, frame_height: 650, manifest: manifest,
        bounds: {south: 48.0, west: -124.5, north: 49.0, east: -123.0})

      expect(wide.zoom).to eq(11)
      expect(wide).not_to be_fully_covered
      expect(wide.tiles).not_to be_empty
    end
  end

  describe "#page_position" do
    let(:view) { view_around(pandora, 2) }

    it "puts the centre at the middle of the frame" do
      position = view.page_position(pandora)

      expect(position.x).to be_within(1e-9).of(262.5)
      expect(position.y).to be_within(1e-9).of(200)
    end

    it "makes x increase eastward and y increase NORTHWARD" do
      centre = view.page_position(pandora)
      north = view.page_position(GeoPoint.new(lat: pandora.lat + 0.01, lng: pandora.lng))
      east = view.page_position(GeoPoint.new(lat: pandora.lat, lng: pandora.lng + 0.01))

      expect(north.y).to be > centre.y
      expect(north.x).to be_within(1e-9).of(centre.x)
      expect(east.x).to be > centre.x
      expect(east.y).to be_within(1e-9).of(centre.y)
    end

    it "keeps a point at the requested radius inside the frame in every direction" do
      (0...360).step(15) do |bearing|
        point = travel(pandora, 2, bearing)

        expect(view.inside_frame?(view.page_position(point))).to be(true), "bearing #{bearing} was outside"
      end
    end

    it "does the same at a radius large enough for the Earth's curve to matter" do
      # The tall frame makes width the tight direction, so the map has no room to spare
      # east and west. The circle's widest points aren't due east and west at this size,
      # so a simple angle / cos(lat) estimate of its reach would leave them off the map.
      wide = view_around(pandora, 3000, height: 2000)

      (0...360).each do |bearing|
        point = travel(pandora, 3000, bearing)

        expect(wide.inside_frame?(wide.page_position(point))).to be(true), "bearing #{bearing} was outside"
      end
    end

    it "scales world pixels by the view's scale" do
      first = view.page_position(pandora)
      second = view.page_position(admirals)
      world_first = MapProjection.to_world(pandora, view.zoom)
      world_second = MapProjection.to_world(admirals, view.zoom)

      expect(first.x - second.x).to be_within(1e-9).of((world_first.x - world_second.x) * view.scale)
    end

    it "keeps real places the right distance apart on the page" do
      # Admirals Rd is 4.4 km west of Pandora. At zoom 14, a world pixel is about 6.34 m.
      gap = view.page_position(pandora).x - view.page_position(admirals).x

      expect(gap).to be_within(5).of(4400 / 6.34 * view.scale)
    end
  end

  describe "#inside_frame?" do
    let(:view) { view_around(pandora, 2) }
    let(:page_point) { MapView::PagePoint }

    it "treats all four corners and the borders as inside" do
      [[0, 0], [525, 0], [0, 400], [525, 400], [0, 200], [525, 200], [262.5, 0], [262.5, 400]].each do |x, y|
        expect(view.inside_frame?(page_point.new(x: x, y: y))).to be true
      end
    end

    it "treats points just past each border as outside" do
      [[-0.01, 200], [525.01, 200], [262.5, -0.01], [262.5, 400.01]].each do |x, y|
        expect(view.inside_frame?(page_point.new(x: x, y: y))).to be false
      end
    end
  end

  describe "#tiles" do
    let(:view) { view_around(pandora, 2) }

    it "makes each tile 256 world pixels wide, in page points" do
      expect(view.tiles).to all(have_attributes(z: 14, size: 256 * view.scale))
    end

    it "lines tiles up with pins, using the same mapping" do
      [pandora, travel(pandora, 1, 45), travel(pandora, 1.5, 200)].each do |point|
        index = MapProjection.tile_for(point, view.zoom)
        tile = view.tiles.find { |candidate| candidate.x == index.x && candidate.y == index.y }
        world = MapProjection.to_world(point, view.zoom)
        position = view.page_position(point)

        expect(position.x).to be_within(1e-9).of(tile.left + (world.x / 256 - index.x) * tile.size)
        expect(position.y).to be_within(1e-9).of(tile.top - (world.y / 256 - index.y) * tile.size)
      end
    end

    it "places neighbouring tiles edge to edge, with higher rows further up the page" do
      tile = view.tiles.first
      right = view.tiles.find { |other| other.x == tile.x + 1 && other.y == tile.y }
      below = view.tiles.find { |other| other.x == tile.x && other.y == tile.y + 1 }

      expect(right.left).to be_within(1e-9).of(tile.right)
      expect(below.top).to be_within(1e-9).of(tile.bottom)
      expect(below.top).to be < tile.top
    end

    it "covers the whole frame when the coverage allows" do
      expect(view.tiles.map(&:left).min).to be <= 0
      expect(view.tiles.map(&:right).max).to be >= 525
      expect(view.tiles.map(&:bottom).min).to be <= 0
      expect(view.tiles.map(&:top).max).to be >= 400
    end

    it "lists exactly the existing tiles that overlap the frame, checked one by one" do
      # Tries every tile near the map on its own terms: a tile should be listed if it
      # overlaps both the frame and the coverage by more than a line.
      view = view_around(GeoPoint.new(lat: 48.30, lng: -123.74), 3)
      size = 256 * view.scale
      centre = MapProjection.to_world(view.centre, view.zoom)
      south_east = MapProjection.to_world(GeoPoint.new(lat: 48.28, lng: -123.2), view.zoom)
      north_west = MapProjection.to_world(GeoPoint.new(lat: 48.72, lng: -123.75), view.zoom)
      column = (centre.x / 256).floor
      row = (centre.y / 256).floor

      expected = (-8..8).to_a.product((-8..8).to_a).filter_map do |dx, dy|
        x = column + dx
        y = row + dy
        left = (x * 256 - centre.x) * view.scale + 262.5
        top = 200 - (y * 256 - centre.y) * view.scale
        in_frame = left < 525 && left + size > 0 && top > 0 && top - size < 400
        in_coverage = x * 256 < south_east.x && (x + 1) * 256 > north_west.x &&
          y * 256 < south_east.y && (y + 1) * 256 > north_west.y
        [x, y] if in_frame && in_coverage
      end

      expect(view.tiles.map { |tile| [tile.x, tile.y] }).to match_array(expected)
      expect(expected).not_to be_empty
    end

    it "skips tiles outside zoom 16's small coverage even where the frame shows that area" do
      # The 30 m area is inside the core, close to its east edge at -123.33, so zoom 16 is
      # chosen. The frame shows about 350 m either side of the centre, past the coverage, so
      # the last tile ends before the frame's right side and leaves a blank strip.
      view = view_around(GeoPoint.new(lat: 48.42, lng: -123.3305), 0.03)
      last_column = MapProjection.tile_for(GeoPoint.new(lat: 48.42, lng: -123.33), 16).x

      expect(view.zoom).to eq(16)
      expect(view).to be_fully_covered
      expect(view.tiles.map(&:x).max).to eq(last_column)
      expect(view.tiles.map(&:right).max).to be < 525
    end

    it "doesn't ask for a neighbouring tile when coverage ends exactly on a tile's edge" do
      edge = MapProjection.to_geo(MapProjection::WorldPoint.new(x: 5155 * 256, y: 11_332 * 256), 15)
      zooms = {min_zoom: 15, max_zoom: 15, zooms: {
        15 => {south: 48.3, west: -123.5, north: 48.5, east: edge.lng}
      }}
      view = view_around(GeoPoint.new(lat: 48.42, lng: edge.lng), 0.3, zooms: zooms)

      expect(view.tiles.map(&:x).max).to eq(5154)
    end

    it "lists tiles top row first, then left to right" do
      order = view.tiles.map { |tile| [tile.y, tile.x] }

      expect(order).to eq(order.sort)
    end

    it "skips tile numbers that don't exist past the world's edge" do
      world = {min_zoom: 11, max_zoom: 11, zooms: {11 => {south: -85, west: -180, north: 85, east: 180}}}
      view = view_around(GeoPoint.new(lat: 0, lng: -179.99), 30, zooms: world)

      expect(view.tiles.map(&:x).min).to eq(0)
    end
  end

  describe "invalid arguments" do
    it "needs exactly one way of describing the area" do
      expect { described_class.new(frame_width: 525, frame_height: 400, manifest: manifest) }.to raise_error(ArgumentError)
      expect { described_class.new(frame_width: 525, frame_height: 400, manifest: manifest, centre: pandora) }.to raise_error(ArgumentError)
      expect {
        described_class.new(frame_width: 525, frame_height: 400, manifest: manifest, bounds: region, centre: pandora, radius_km: 1)
      }.to raise_error(ArgumentError)
    end

    it "rejects a frame with no size, a negative radius, inverted bounds and an empty manifest" do
      expect { view_around(pandora, 1, width: 0) }.to raise_error(ArgumentError)
      expect { view_around(pandora, -1) }.to raise_error(ArgumentError)
      expect {
        described_class.new(frame_width: 525, frame_height: 400, manifest: manifest, bounds: region.merge(south: 49))
      }.to raise_error(ArgumentError)
      expect { view_around(pandora, 1, zooms: {min_zoom: 11, max_zoom: 16, zooms: {}}) }.to raise_error(ArgumentError)
    end
  end
end
