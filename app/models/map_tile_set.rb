# The stored map tiles in lib/map_tiles: what they cover, where each file is, and the credit
# they require.
#
# Architecture: this is the only class that knows how the tile folder is laid out. MapView
# deliberately reads no files, so it's handed `view_manifest`, and FlyerMapPage asks here for
# the file behind each tile that MapView chooses.
#
# Why it exists: the build script's manifest.json describes each zoom with an entry in a
# `zooms` array, holding `covered_bounds`. MapView expects a hash keyed by zoom. Converting
# here means neither the build script nor MapView has to know about the other's format.
class MapTileSet
  ROOT = Rails.root.join("lib/map_tiles")

  # One shared copy, because the manifest never changes while the app runs and every printout
  # needs it.
  def self.default
    @default ||= new(ROOT)
  end

  attr_reader :attribution, :style_credit

  def initialize(root)
    @root = Pathname(root)
    manifest = JSON.parse(@root.join("manifest.json").read)
    @template = manifest.fetch("path_template")
    @levels = manifest.fetch("zoom_levels")
    @zooms = manifest.fetch("zooms")
    @attribution = manifest.fetch("attribution")
    @style_credit = manifest.fetch("style_credit")
  end

  # The manifest in the shape MapView.new takes.
  def view_manifest
    {
      min_zoom: @levels.min,
      max_zoom: @levels.max,
      zooms: @zooms.to_h { |entry| [entry.fetch("zoom"), entry.fetch("covered_bounds")] }
    }
  end

  # The file for a MapView::Tile, or nil if it doesn't exist. MapView assumes every tile
  # within a zoom's bounds was built, so a nil here means a gap in the stored set. The map
  # can still print with a blank square, which is better than no guide at all.
  def path_for(tile)
    relative = @template.sub("{z}", tile.z.to_s).sub("{x}", tile.x.to_s).sub("{y}", tile.y.to_s)
    path = @root.join(relative)
    path.to_s if path.file?
  end
end
