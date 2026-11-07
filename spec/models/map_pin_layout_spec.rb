require "rails_helper"

# Covers deciding what each resource becomes: a pin, an edge marker or a "not shown" entry,
# including merging, sorting and duplicates. Most examples place resources by page position,
# using a helper that works out the GeoPoint for a spot on the page.
#
# Doesn't cover drawing, whether the assumed pin and marker sizes look right on paper, or
# which tiles get drawn (see map_view_spec.rb).
RSpec.describe MapPinLayout do
  let(:manifest) do
    region = {south: 48.28, west: -123.75, north: 48.72, east: -123.2}
    {min_zoom: 11, max_zoom: 15, zooms: (11..15).to_h { |zoom| [zoom, region] }}
  end
  let(:pandora) { GeoPoint.new(lat: 48.4271129, lng: -123.3577635) }
  let(:admirals) { GeoPoint.new(lat: 48.4284587, lng: -123.4174225) }
  # A 525 x 400 frame centred on 919 Pandora, so the frame's centre is (262.5, 200).
  let(:view) do
    MapView.new(frame_width: 525, frame_height: 400, manifest: manifest, centre: pandora, radius_km: 1)
  end
  let(:inset) { described_class::EDGE_MARKER_INSET }

  def item(number, point, title: "Resource #{number}")
    described_class::Item.new(number: number, title: title, point: point)
  end

  # The GeoPoint that lands on a given spot on the page. It undoes the view's mapping using
  # only its public values, so it can also make points that are off the page.
  def geo_at(x, y)
    centre = MapProjection.to_world(view.centre, view.zoom)
    world = MapProjection::WorldPoint.new(
      x: centre.x + (x - 262.5) / view.scale,
      y: centre.y - (y - 200) / view.scale
    )
    MapProjection.to_geo(world, view.zoom)
  end

  def layout(*items)
    described_class.new(view, items)
  end

  describe "pins" do
    it "places a resource inside the frame at its page position" do
      pin = layout(item(1, pandora)).pins.first

      expect(pin.x).to be_within(1e-9).of(262.5)
      expect(pin.y).to be_within(1e-9).of(200)
      expect(pin.label).to eq("1")
      expect(pin.titles).to eq(["Resource 1"])
    end

    it "uses a pin for points on the frame's corners and borders" do
      spots = [[0, 0], [525, 0], [0, 400], [525, 400], [262.5, 0], [262.5, 400], [0, 200], [525, 200]]
      items = spots.each_with_index.map { |(x, y), index| item(index + 1, geo_at(x, y)) }
      result = described_class.new(view, items)

      expect(result.pins.size).to eq(8)
      expect(result.edge_markers).to be_empty
      expect(result.pins.first.x).to be_within(1e-6).of(0)
      expect(result.pins.first.y).to be_within(1e-6).of(0)
    end

    it "uses an edge marker for a point just past the border" do
      result = layout(item(1, geo_at(525.5, 200)))

      expect(result.pins).to be_empty
      expect(result.edge_markers.size).to eq(1)
    end

    it "merges resources at the same spot, listing numbers in numeric order" do
      result = layout(item(10, pandora), item(3, pandora), item(7, pandora))

      expect(result.pins.size).to eq(1)
      expect(result.pins.first.label).to eq("3, 7, 10")
      expect(result.pins.first.titles).to eq(["Resource 3", "Resource 7", "Resource 10"])
    end

    it "merges pins just within the merge distance, placing them in the middle" do
      distance = described_class::PIN_MERGE_DISTANCE
      result = layout(item(3, geo_at(100, 100)), item(7, geo_at(100 + distance - 0.01, 100)))

      expect(result.pins.size).to eq(1)
      expect(result.pins.first.label).to eq("3, 7")
      expect(result.pins.first.x).to be_within(1e-6).of(100 + (distance - 0.01) / 2)
    end

    it "keeps pins just past the merge distance apart" do
      distance = described_class::PIN_MERGE_DISTANCE
      result = layout(item(3, geo_at(100, 100)), item(7, geo_at(100 + distance + 0.01, 100)))

      expect(result.pins.map(&:label)).to eq(["3", "7"])
    end

    it "doesn't chain a line of pins into one distant pin" do
      # Each is within the merge distance of the next, but not of the one after that.
      spots = (0..3).map { |step| 100 + step * described_class::PIN_MERGE_DISTANCE * 0.8 }
      result = described_class.new(view, spots.each_with_index.map { |x, index| item(index + 1, geo_at(x, 100)) })

      expect(result.pins.map(&:label)).to eq(["1, 2", "3, 4"])
    end

    it "never moves a merged pin further than the merge distance from its members" do
      spots = [[100, 100], [104, 102], [101, 104], [103, 99], [105, 105]]
      positions = spots.map { |x, y| view.page_position(geo_at(x, y)) }
      result = described_class.new(view, spots.each_with_index.map { |(x, y), index| item(index + 1, geo_at(x, y)) })

      result.pins.each do |pin|
        pin.numbers.each do |number|
          position = positions[number - 1]
          expect(Math.hypot(pin.x - position.x, pin.y - position.y)).to be <= described_class::PIN_MERGE_DISTANCE
        end
      end
    end

    it "keeps two resources at one spot together, even beside a nearby group" do
      result = layout(item(1, geo_at(100, 100)), item(2, geo_at(107, 100)), item(3, geo_at(103, 100)), item(4, geo_at(103, 100)))
      group = result.pins.find { |pin| pin.numbers.include?(3) }

      expect(group.numbers).to include(4)
    end
  end

  describe "edge markers" do
    # Each resource is far enough off the page that its line is clear of the frame.
    it "marks a resource due north at the top, pointing up" do
      marker = layout(item(1, GeoPoint.new(lat: pandora.lat + 1, lng: pandora.lng))).edge_markers.first

      expect(marker.x).to be_within(1e-9).of(262.5)
      expect(marker.y).to be_within(1e-9).of(400 - inset)
      expect(marker.angle_degrees).to eq(90)
      expect(marker.min_km).to be_within(0.1).of(111.2)
    end

    it "marks a resource due south at the bottom, pointing down" do
      marker = layout(item(1, GeoPoint.new(lat: pandora.lat - 1, lng: pandora.lng))).edge_markers.first

      expect(marker.x).to be_within(1e-9).of(262.5)
      expect(marker.y).to be_within(1e-9).of(inset)
      expect(marker.angle_degrees).to eq(270)
    end

    it "marks a resource due east at the right, pointing right" do
      marker = layout(item(1, GeoPoint.new(lat: pandora.lat, lng: pandora.lng + 1))).edge_markers.first

      expect(marker.x).to be_within(1e-9).of(525 - inset)
      expect(marker.y).to be_within(1e-9).of(200)
      expect(marker.angle_degrees).to eq(0)
    end

    it "marks a resource due west at the left, pointing left" do
      marker = layout(item(1, GeoPoint.new(lat: pandora.lat, lng: pandora.lng - 1))).edge_markers.first

      expect(marker.x).to be_within(1e-9).of(inset)
      expect(marker.y).to be_within(1e-9).of(200)
      expect(marker.angle_degrees).to eq(180)
    end

    it "marks all four diagonals where their lines cross the inset border" do
      # The inset frame is 186 points from the centre vertically, closer than the 248.5 points
      # horizontally, so a 45 degree line reaches the top or bottom first.
      {
        [1000, 1000] => [45, 262.5 + 186, 200 + 186],
        [-1000, 1000] => [135, 262.5 - 186, 200 + 186],
        [-1000, -1000] => [225, 262.5 - 186, 200 - 186],
        [1000, -1000] => [315, 262.5 + 186, 200 - 186]
      }.each do |(right, up), (angle, x, y)|
        marker = layout(item(1, geo_at(262.5 + right, 200 + up))).edge_markers.first

        expect(marker.angle_degrees).to be_within(1e-5).of(angle)
        expect(marker.x).to be_within(1e-6).of(x)
        expect(marker.y).to be_within(1e-6).of(y)
      end
    end

    it "puts a marker aimed at the frame's corner in the inset corner's region" do
      marker = layout(item(1, geo_at(525 * 2 - 262.5, 400 * 2 - 200))).edge_markers.first

      expect(marker.angle_degrees).to be_within(1e-5).of(Math.atan2(200, 262.5) * 180 / Math::PI)
      expect(marker.y).to be_within(1e-6).of(400 - inset)
      expect(marker.x).to be <= 525 - inset
    end

    it "keeps a marker on the straight line from the frame's centre" do
      result = layout(item(1, geo_at(900, 300)))
      marker = result.edge_markers.first

      expect((marker.y - 200) / (marker.x - 262.5)).to be_within(1e-6).of(100.0 / 637.5)
      expect(marker.x).to be_within(1e-6).of(525 - inset)
    end

    it "keeps every marker fully inside the frame" do
      items = (0...24).map do |index|
        angle = index * 15 * Math::PI / 180
        item(index + 1, geo_at(262.5 + Math.cos(angle) * 2000, 200 + Math.sin(angle) * 2000))
      end

      described_class.new(view, items).edge_markers.each do |marker|
        expect(marker.x).to be_between(inset - 1e-6, 525 - inset + 1e-6)
        expect(marker.y).to be_between(inset - 1e-6, 400 - inset + 1e-6)
      end
    end

    it "points to a real address, with its real distance" do
      # 500 Admirals is 4.4 km away, west and slightly north. By hand: the latitude change of
      # 0.001346 stretches to 0.00203 at this latitude, against 0.05966 of longitude, so it
      # sits 1.95 degrees north of due west.
      marker = layout(item(1, admirals)).edge_markers.first

      expect(marker.angle_degrees).to be_within(0.01).of(178.05)
      expect(marker.min_km).to be_within(0.1).of(4.4)
      expect(marker.max_km).to eq(marker.min_km)
      expect(marker.distance_label).to eq("4.4 km")
      expect(marker.x).to be_within(1e-6).of(inset)
    end

    it "measures distance from the map's centre with GeoPoint, not along the page" do
      point = GeoPoint.new(lat: pandora.lat, lng: pandora.lng + 1)

      expect(layout(item(1, point)).edge_markers.first.min_km).to eq(pandora.distance_km_to(point))
    end

    it "merges nearby markers, listing numbers and a distance range" do
      near = GeoPoint.new(lat: pandora.lat + 0.1, lng: pandora.lng)
      far = GeoPoint.new(lat: pandora.lat + 0.3, lng: pandora.lng)
      marker = layout(item(9, far), item(2, near)).edge_markers.first

      expect(layout(item(9, far), item(2, near)).edge_markers.size).to eq(1)
      expect(marker.label).to eq("2, 9")
      expect(marker.titles).to eq(["Resource 2", "Resource 9"])
      expect(marker.min_km).to be_within(0.1).of(11.1)
      expect(marker.max_km).to be_within(0.1).of(33.4)
      expect(marker.distance_label).to eq("11.1–33.4 km")
      expect(marker.angle_degrees).to eq(90)
    end

    it "keeps a single distance when a range would round to the same number" do
      first = GeoPoint.new(lat: pandora.lat + 0.1, lng: pandora.lng)
      second = GeoPoint.new(lat: pandora.lat + 0.1001, lng: pandora.lng)

      expect(layout(item(1, first), item(2, second)).edge_markers.first.distance_label).to eq("11.1 km")
    end

    it "keeps markers just past the merge distance apart" do
      # Walking 2485 points right to reach the inset side, 248.5 points away, is a tenth of
      # the way there. So these land at a tenth of their height: 15 and 45 points up.
      result = layout(item(1, geo_at(262.5 + 2485, 200 + 150)), item(2, geo_at(262.5 + 2485, 200 + 450)))

      expect(result.edge_markers.size).to eq(2)
      expect(result.edge_markers[1].y - result.edge_markers[0].y).to be_within(1e-6).of(30)
    end

    it "merges markers either side of due east to point east, not west" do
      # Averaging 2 and 358 as plain numbers would give 180, which is the opposite way.
      result = layout(item(1, geo_at(262.5 + 2000, 200 + 70)), item(2, geo_at(262.5 + 2000, 200 - 70)))
      marker = result.edge_markers.first

      expect(result.edge_markers.size).to eq(1)
      expect(marker.angle_degrees).to be_within(1e-5).of(0).or be_within(1e-5).of(360)
      expect(marker.x).to be_within(1e-6).of(525 - inset)
      expect(marker.y).to be_within(1e-6).of(200)
    end

    it "keeps markers in opposite directions apart" do
      result = layout(
        item(1, GeoPoint.new(lat: pandora.lat, lng: pandora.lng + 1)),
        item(2, GeoPoint.new(lat: pandora.lat, lng: pandora.lng - 1))
      )

      expect(result.edge_markers.map(&:label)).to eq(["1", "2"])
    end

    it "keeps a marker in a frame too small to inset" do
      tiny = MapView.new(frame_width: 20, frame_height: 20, manifest: manifest, centre: pandora, radius_km: 1)
      marker = described_class.new(tiny, [item(1, admirals)]).edge_markers.first

      expect(marker.x).to be_within(1e-9).of(10)
      expect(marker.y).to be_within(1e-9).of(10)
    end
  end

  describe "resources with no usable location" do
    it "lists a resource with no coordinates" do
      result = layout(item(4, nil, title: "The Cridge Transition House"))

      expect(result.not_shown).to eq([described_class::NotShown.new(number: 4, title: "The Cridge Transition House")])
      expect(result.pins).to be_empty
      expect(result.edge_markers).to be_empty
    end

    it "lists impossible coordinates instead of pointing to nowhere" do
      result = layout(item(1, GeoPoint.new(lat: 999, lng: -123.36)), item(2, GeoPoint.new(lat: 48.4, lng: -500)),
        item(3, GeoPoint.new(lat: Float::NAN, lng: -123.36)), item(4, GeoPoint.new(lat: nil, lng: nil)))

      expect(result.not_shown.map(&:number)).to eq([1, 2, 3, 4])
    end
  end

  describe "duplicates" do
    it "shows a resource once when it arrives twice" do
      result = layout(item(3, pandora), item(3, pandora))

      expect(result.pins.size).to eq(1)
      expect(result.pins.first.numbers).to eq([3])
    end

    it "prefers the copy with coordinates, whichever order they arrive in" do
      first = layout(item(3, nil), item(3, pandora))
      second = layout(item(3, pandora), item(3, nil))

      [first, second].each do |result|
        expect(result.pins.map(&:numbers)).to eq([[3]])
        expect(result.not_shown).to be_empty
      end
    end

    it "lists a duplicate with no coordinates once" do
      expect(layout(item(3, nil), item(3, nil)).not_shown.size).to eq(1)
    end

    it "gives the same answer for conflicting copies in either order" do
      first = layout(item(3, pandora, title: "A"), item(3, admirals, title: "B"))
      second = layout(item(3, admirals, title: "B"), item(3, pandora, title: "A"))

      expect(first.pins).to eq(second.pins)
      expect(first.edge_markers).to eq(second.edge_markers)
    end
  end

  describe "ordering" do
    let(:mixed_items) do
      [
        item(12, geo_at(400, 300)), item(2, geo_at(100, 100)), item(30, geo_at(100, 100)),
        item(5, GeoPoint.new(lat: pandora.lat + 1, lng: pandora.lng)),
        item(1, GeoPoint.new(lat: pandora.lat, lng: pandora.lng - 1)),
        item(20, nil), item(4, nil)
      ]
    end

    it "sorts each list by number" do
      result = described_class.new(view, mixed_items)

      expect(result.pins.map(&:label)).to eq(["2, 30", "12"])
      expect(result.edge_markers.map(&:label)).to eq(["1", "5"])
      expect(result.not_shown.map(&:number)).to eq([4, 20])
    end

    it "gives identical results whatever order the input is in" do
      expected = described_class.new(view, mixed_items)

      [mixed_items.reverse, mixed_items.rotate(3), mixed_items.shuffle(random: Random.new(42))].each do |order|
        result = described_class.new(view, order)

        expect(result.pins).to eq(expected.pins)
        expect(result.edge_markers).to eq(expected.edge_markers)
        expect(result.not_shown).to eq(expected.not_shown)
      end
    end

    it "accepts any object with a number, title and point" do
      resource = Struct.new(:number, :title, :point).new(1, "Our Place", pandora)

      expect(described_class.new(view, [resource]).pins.first.label).to eq("1")
    end
  end

  describe "edge cases of the whole list" do
    it "handles an empty list" do
      result = layout

      expect(result.pins).to eq([])
      expect(result.edge_markers).to eq([])
      expect(result.not_shown).to eq([])
    end

    it "handles every resource being off the map" do
      result = layout(item(1, admirals), item(2, GeoPoint.new(lat: 49.2827, lng: -123.1207)))

      expect(result.pins).to be_empty
      expect(result.edge_markers.flat_map(&:numbers)).to eq([1, 2])
    end
  end
end
