require "rails_helper"

# Covers the Web Mercator maths: GeoPoint to world pixels and back, the latitude limit, and
# which tile a point falls in.
#
# The expected numbers don't come from MapProjection itself. They come from a worked example
# published on the OpenStreetMap wiki, simple geometry (the origin and corners), and values
# worked out separately in Python with a different form of the formula (asinh(tan(lat))).
#
# Doesn't cover frames, scale or page positions (see map_view_spec.rb), or whether real tile
# files match these numbers, because the tiles haven't been built yet.
RSpec.describe MapProjection do
  let(:pandora) { GeoPoint.new(lat: 48.4271129, lng: -123.3577635) }
  let(:admirals) { GeoPoint.new(lat: 48.4284587, lng: -123.4174225) }
  let(:limit) { described_class::MAX_LATITUDE }

  describe ".world_size" do
    it "is 256 at zoom 0 and doubles with each zoom, ignoring the images' double resolution" do
      expect(described_class.world_size(0)).to eq(256)
      expect(described_class.world_size(1)).to eq(512)
      expect(described_class.world_size(15)).to eq(8_388_608)
    end
  end

  describe ".to_world" do
    it "puts latitude 0, longitude 0 at the middle of the world" do
      world = described_class.to_world(GeoPoint.new(lat: 0, lng: 0), 11)

      expect(world.x).to be_within(1e-6).of(262_144)
      expect(world.y).to be_within(1e-6).of(262_144)
    end

    it "puts the north-west corner at the origin and the south-east corner at the far end" do
      north_west = described_class.to_world(GeoPoint.new(lat: limit, lng: -180), 3)
      south_east = described_class.to_world(GeoPoint.new(lat: -limit, lng: 180), 3)

      expect(north_west.x).to be_within(1e-6).of(0)
      expect(north_west.y).to be_within(1e-6).of(0)
      expect(south_east.x).to be_within(1e-6).of(2048)
      expect(south_east.y).to be_within(1e-6).of(2048)
    end

    it "matches values worked out separately in Python" do
      world = described_class.to_world(pandora, 15)
      expect(world.x).to be_within(1e-5).of(1_319_859.772894)
      expect(world.y).to be_within(1e-5).of(2_901_065.310628)

      world = described_class.to_world(admirals, 16)
      expect(world.x).to be_within(1e-5).of(2_636_939.234873)
      expect(world.y).to be_within(1e-5).of(5_802_036.103056)
    end

    it "doubles a position's coordinates with each zoom" do
      lower = described_class.to_world(pandora, 14)
      higher = described_class.to_world(pandora, 15)

      expect(higher.x).to be_within(1e-6).of(lower.x * 2)
      expect(higher.y).to be_within(1e-6).of(lower.y * 2)
    end

    it "makes y grow southward and x grow eastward" do
      north = described_class.to_world(GeoPoint.new(lat: 48.5, lng: -123.4), 15)
      south = described_class.to_world(GeoPoint.new(lat: 48.4, lng: -123.3), 15)

      expect(south.y).to be > north.y
      expect(south.x).to be > north.x
    end

    it "clamps latitudes past the limit, including the poles" do
      at_limit = described_class.to_world(GeoPoint.new(lat: limit, lng: 0), 5)

      expect(described_class.to_world(GeoPoint.new(lat: 90, lng: 0), 5)).to eq(at_limit)
      expect(described_class.to_world(GeoPoint.new(lat: 89, lng: 0), 5)).to eq(at_limit)
      expect(described_class.to_world(GeoPoint.new(lat: -90, lng: 0), 5).y).to be_within(1e-6).of(8192)
    end

    it "accepts whole-number coordinates" do
      expect(described_class.to_world(GeoPoint.new(lat: 0, lng: 90), 0).x).to eq(192)
    end
  end

  describe ".to_geo" do
    it "reverses to_world for Victoria addresses at every zoom we store" do
      (11..16).each do |zoom|
        [pandora, admirals].each do |point|
          back = described_class.to_geo(described_class.to_world(point, zoom), zoom)

          expect(back.lat).to be_within(1e-9).of(point.lat)
          expect(back.lng).to be_within(1e-9).of(point.lng)
        end
      end
    end

    it "maps the world's corners and middle to the expected places" do
      world = MapProjection::WorldPoint

      middle = described_class.to_geo(world.new(x: 128, y: 128), 0)
      expect(middle.lat).to be_within(1e-9).of(0)
      expect(middle.lng).to be_within(1e-9).of(0)

      corner = described_class.to_geo(world.new(x: 0, y: 0), 0)
      expect(corner.lat).to be_within(1e-9).of(limit)
      expect(corner.lng).to be_within(1e-9).of(-180)

      corner = described_class.to_geo(world.new(x: 256, y: 256), 0)
      expect(corner.lat).to be_within(1e-9).of(-limit)
      expect(corner.lng).to be_within(1e-9).of(180)
    end
  end

  describe ".tile_for" do
    it "finds the OpenStreetMap wiki's published example, the Hachiko statue" do
      # https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames gives /18/232798/103246.png.
      tile = described_class.tile_for(GeoPoint.new(lat: 35.6590699, lng: 139.7006793), 18)

      expect(tile).to eq(MapProjection::TileIndex.new(z: 18, x: 232_798, y: 103_246))
    end

    it "matches the standard slippy-map formula for downtown Victoria at zoom 15" do
      # The wiki's form of the formula, written out here so it doesn't share code with
      # MapProjection: n * (lng + 180) / 360 and n * (1 - ln(tan(lat) + sec(lat)) / pi) / 2.
      lat = 48.4265 * Math::PI / 180
      n = 2**15
      expected_x = (n * (-123.3656 + 180) / 360).floor
      expected_y = (n * (1 - Math.log(Math.tan(lat) + 1 / Math.cos(lat)) / Math::PI) / 2).floor

      tile = described_class.tile_for(GeoPoint.new(lat: 48.4265, lng: -123.3656), 15)

      expect([expected_x, expected_y]).to eq([5154, 11_332])
      expect(tile).to eq(MapProjection::TileIndex.new(z: 15, x: 5154, y: 11_332))
    end

    it "separates two Victoria addresses into the right neighbouring tiles" do
      expect(described_class.tile_for(pandora, 15).x).to eq(5155)
      expect(described_class.tile_for(admirals, 15).x).to eq(5150)
    end

    it "uses the only tile at zoom 0" do
      expect(described_class.tile_for(pandora, 0)).to eq(MapProjection::TileIndex.new(z: 0, x: 0, y: 0))
    end

    it "keeps the world's far edges on the last real tile" do
      tile = described_class.tile_for(GeoPoint.new(lat: -90, lng: 180), 2)

      expect(tile).to eq(MapProjection::TileIndex.new(z: 2, x: 3, y: 3))
    end

    it "keeps the north-west corner on tile 0, 0" do
      tile = described_class.tile_for(GeoPoint.new(lat: 90, lng: -180), 2)

      expect(tile).to eq(MapProjection::TileIndex.new(z: 2, x: 0, y: 0))
    end
  end
end
