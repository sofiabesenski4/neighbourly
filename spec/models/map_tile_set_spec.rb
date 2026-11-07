require "rails_helper"

# Runs against the real stored tiles, because the point of this class is matching what the
# build script actually produced.
RSpec.describe MapTileSet do
  subject(:tile_set) { described_class.default }

  describe "#view_manifest" do
    it "converts the build script's manifest to what MapView expects" do
      manifest = tile_set.view_manifest

      expect(manifest.slice(:min_zoom, :max_zoom)).to eq(min_zoom: 11, max_zoom: 16)
      expect(manifest[:zooms].keys).to contain_exactly(11, 12, 13, 14, 15, 16)
      expect(manifest[:zooms][16]).to include("west", "south", "east", "north")
    end
  end

  describe "#path_for" do
    def tile(z:, x:, y:)
      MapView::Tile.new(z: z, x: x, y: y, left: 0, top: 0, size: 100)
    end

    it "finds a stored tile" do
      expect(tile_set.path_for(tile(z: 11, x: 320, y: 705))).to end_with("lib/map_tiles/11/320/705.png")
    end

    it "gives nil for a tile that wasn't built" do
      expect(tile_set.path_for(tile(z: 11, x: 0, y: 0))).to be_nil
    end
  end

  # MapView assumes tiles exist wherever the manifest's bounds say. This checks the
  # assumption holds for the map most guides print.
  it "has every tile MapView asks for around downtown" do
    view = MapView.new(frame_width: 525, frame_height: 640, manifest: tile_set.view_manifest,
      centre: FlyerMapPage::DOWNTOWN, radius_km: FlyerMapPage::RADIUS_KM)

    expect(view.tiles).not_to be_empty
    expect(view.tiles.map { |tile| tile_set.path_for(tile) }).to all(be_present)
  end

  it "credits the map data as its licence requires" do
    expect(tile_set.attribution).to eq("© OpenMapTiles © OpenStreetMap contributors")
    expect(tile_set.style_credit).to include("Positron")
  end
end
