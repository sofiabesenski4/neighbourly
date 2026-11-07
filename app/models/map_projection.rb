# Web Mercator maths: turns a latitude and longitude into a position on a flat,
# square picture of the world, and back again.
#
# Architecture: this is the bottom layer of the printable resource map. MapView uses it
# to place tiles and pins, and MapPinLayout works from MapView's answers. It knows
# nothing about PDFs, tile files or resources. It takes GeoPoints and gives back
# "world pixels", which are explained below.
#
# Why it exists: stored map tiles are cut using these exact formulas. A pin only lands on
# the right street if it's positioned with the same maths the tiles were made with, so
# that maths lives here, once.
#
# What a world pixel is: imagine the whole world drawn as one square image. At zoom 0 the
# square is 256 units wide, and each zoom level doubles its width, so it's 256 * 2**zoom
# units wide. Those units are world pixels. Position (0, 0) is the top-left corner, in
# the Pacific and far north. x grows eastward and y grows SOUTHWARD, like an image and
# unlike a PDF page. MapView does the flip.
#
# A world pixel is not an image pixel. Our PNG tiles are 512x512 so they print sharply,
# but each still covers 256 world pixels. That's why TILE_SIZE is 256 here.
module MapProjection
  # How many world pixels one tile covers along each side, whatever the PNG's real size.
  TILE_SIZE = 256

  # The furthest north or south Web Mercator can show. The projection stretches
  # north-south distances more and more towards the poles, and at the poles themselves
  # the stretch becomes infinite. This latitude, atan(sinh(pi)), is where the map becomes
  # exactly square, so it's where every web map stops.
  MAX_LATITUDE = 85.05112877980659

  # A position in world pixels. It has no zoom of its own, so it only means something
  # alongside the zoom it was calculated for.
  WorldPoint = Data.define(:x, :y)

  # The address of one tile in the standard XYZ numbering, where tile (0, 0) is the
  # top-left corner of the world at that zoom.
  TileIndex = Data.define(:z, :x, :y)

  # How wide (and tall) the whole world is at this zoom, in world pixels.
  def self.world_size(zoom)
    TILE_SIZE * 2**zoom
  end

  # Finds where a GeoPoint falls in the world square at this zoom.
  #
  # Longitude is simple: -180 to 180 degrees is spread evenly across the width.
  #
  # Latitude is not even. To keep shapes looking right, Mercator stretches north-south
  # distances by the same amount that east-west distances are stretched at that latitude.
  # Adding up that growing stretch from the equator gives ln(tan(45 degrees + lat / 2)),
  # which is 0 at the equator and +/-pi at the Mercator limit. Dividing by pi gives a value
  # from -1 to 1. The rest turns that into 0 at the top of the square and 1 at the bottom.
  #
  # Latitude is clamped because the formula runs off the square past the limit, and
  # reaches infinity at the poles. Longitude is left alone: nothing valid is out of range.
  def self.to_world(point, zoom)
    size = world_size(zoom)
    lat = point.lat.to_f.clamp(-MAX_LATITUDE, MAX_LATITUDE)
    stretched = Math.log(Math.tan(Math::PI / 4 + radians(lat) / 2))

    WorldPoint.new(
      x: (point.lng.to_f + 180) / 360 * size,
      y: (1 - stretched / Math::PI) / 2 * size
    )
  end

  # The reverse of to_world: which GeoPoint sits at this world position. The latitude line
  # undoes the stretch above, using the standard inverse, atan(sinh(value)).
  def self.to_geo(world, zoom)
    size = world_size(zoom).to_f
    stretched = Math::PI * (1 - 2 * world.y / size)

    GeoPoint.new(
      lat: degrees(Math.atan(Math.sinh(stretched))),
      lng: world.x / size * 360 - 180
    )
  end

  # Which tile holds this GeoPoint. The clamp is for the world's far edges: longitude 180
  # lands exactly on x = world_size, which would otherwise name a tile one past the end.
  def self.tile_for(point, zoom)
    world = to_world(point, zoom)
    last = 2**zoom - 1

    TileIndex.new(
      z: zoom,
      x: (world.x / TILE_SIZE).floor.clamp(0, last),
      y: (world.y / TILE_SIZE).floor.clamp(0, last)
    )
  end

  def self.radians(value)
    value * Math::PI / 180
  end
  private_class_method :radians

  def self.degrees(value)
    value * 180 / Math::PI
  end
  private_class_method :degrees
end
