# Decides exactly what one printed map shows: which zoom, how large it's drawn, where any
# GeoPoint lands on the page, and which tiles to draw.
#
# Architecture: FlyerMapPage builds one MapView for each map, draws `tiles`, then passes
# the view to MapPinLayout to work out the pins and edge markers. It sits between
# MapProjection, which knows the world's geometry, and FlyerMapPage, which knows about
# Prawn. See docs/printed-map.md. This class reads no files and draws nothing: it's told what tiles exist
# through a manifest hash, so it can be tested with plain numbers.
#
# Why it exists: tiles and pins must never drift apart. Both go through
# page_position_for_world, so a pin can't disagree with the streets under it.
#
# Coordinates here come in three kinds:
# - GeoPoint: degrees on Earth.
# - World pixels: see MapProjection. y grows downward.
# - Page points: the PDF's units (1/72 inch), measured from the frame's bottom-left
#   corner. y grows UPWARD, as in Prawn. Scale converts world pixels to page points.
#
# Usage:
#   manifest = {min_zoom: 11, max_zoom: 16, zooms: {15 => region, 16 => urban_core}}
#   view = MapView.new(frame_width: 525, frame_height: 400, manifest: manifest,
#     centre: GeoPoint.new(lat: 48.4271129, lng: -123.3577635), radius_km: 2)
#   view.zoom                       # the chosen zoom
#   view.page_position(some_point)  # a PagePoint, which may be outside the frame
#   view.tiles                      # what to draw
class MapView
  # The range of sizes a tile can be drawn at, in page points per world pixel. Zoom only
  # comes in steps that double the map's size, so scale makes up the difference between
  # those steps and what exactly fits the frame.
  #
  # The PNGs hold 2 image pixels per world pixel, so print sharpness is 144 / scale dots
  # per inch. Text on plain map styles is typically about 11 world pixels tall, so it
  # prints at about 11 * scale points.
  #
  # MIN_SCALE: below 0.6, the map's text would print under about 6.6 points, which is hard
  # to read, so we pick a less detailed zoom instead. MAX_SCALE: above 1.2, tiles would
  # drop under 120 dpi and look soft. It's twice MIN_SCALE because the fit scale doubles
  # with each zoom step, so some zoom usually lands inside the range. These are estimates
  # from the numbers above and haven't been checked on a printed page.
  MIN_SCALE = 0.6
  MAX_SCALE = 1.2

  # How far past the border still counts as inside the frame, in page points. Converting
  # to degrees and back can leave a point on the border a billionth of a point outside. A
  # millionth of a point is invisible, so this only removes that rounding noise.
  BORDER_TOLERANCE = 1e-6

  # An area of the Earth, in degrees. The manifest's coverage and area-wide maps both use
  # this. West must be less than east, so an area can't cross the 180 degree meridian.
  class Bounds < Data.define(:south, :west, :north, :east)
    # Accepts a Bounds or a hash with symbol or string keys, as parsed JSON gives.
    def self.from(value)
      return value if value.is_a?(self)

      fields = value.to_h.symbolize_keys
      new(south: fields.fetch(:south), west: fields.fetch(:west),
        north: fields.fetch(:north), east: fields.fetch(:east))
    end

    def initialize(south:, west:, north:, east:)
      raise ArgumentError, "south must not be above north" if south > north
      raise ArgumentError, "west must not be past east" if west > east

      super(south: south.to_f, west: west.to_f, north: north.to_f, east: east.to_f)
    end

    # Whether another area sits completely within this one. Touching the edge counts.
    def contains?(other)
      south <= other.south && north >= other.north && west <= other.west && east >= other.east
    end
  end

  # A position on the page, relative to the frame's bottom-left corner.
  PagePoint = Data.define(:x, :y)

  # One tile to draw. z, x and y name the file. Left and top are its top-left corner
  # because that's what Prawn's `image at:` expects, even though y grows upward. Size is
  # both its width and height in page points.
  class Tile < Data.define(:z, :x, :y, :left, :top, :size)
    def right
      left + size
    end

    def bottom
      top - size
    end
  end

  attr_reader :frame_width, :frame_height, :zoom, :scale

  # Give either bounds (an area-wide map), or centre and radius_km.
  def initialize(frame_width:, frame_height:, manifest:, bounds: nil, centre: nil, radius_km: nil)
    raise ArgumentError, "the frame must have a positive size" unless frame_width.positive? && frame_height.positive?
    described = bounds ? centre.nil? && radius_km.nil? : centre && radius_km
    raise ArgumentError, "give either bounds, or a centre and radius_km" unless described
    raise ArgumentError, "radius_km must not be negative" if radius_km&.negative?

    @frame_width = frame_width.to_f
    @frame_height = frame_height.to_f
    @coverage = parse_coverage(manifest)
    @requested_area = bounds ? Bounds.from(bounds) : area_around(centre, radius_km)
    @given_centre = centre

    @zoom = choose_zoom
    @scale = [fit_scale(@zoom), MAX_SCALE].min
    @frame_centre = world_centre_at(@zoom)
  end

  # The place at the middle of the frame, which edge marker distances are measured from.
  # A given centre comes back exactly as given, with no rounding from a round trip.
  def centre
    @given_centre || MapProjection.to_geo(@frame_centre, @zoom)
  end

  # Where a GeoPoint lands, relative to the frame. It may be outside the frame.
  def page_position(point)
    page_position_for_world(MapProjection.to_world(point, @zoom))
  end

  # How many page points one km takes up at the frame's centre, for a scale bar. A km covers
  # more world pixels further north, because Mercator stretches by 1 / cos(latitude). The
  # Earth's circumference at this latitude is 2 * pi * radius * cos(latitude), and the whole
  # world is world_size pixels wide. A map this small hardly varies from top to bottom.
  def points_per_km
    circumference = 2 * Math::PI * GeoPoint::EARTH_RADIUS_KM * Math.cos(centre.lat * Math::PI / 180)

    MapProjection.world_size(@zoom) / circumference * @scale
  end

  # Whether a PagePoint is inside the frame. Points on the border count as inside.
  def inside_frame?(page_point)
    page_point.x.between?(-BORDER_TOLERANCE, @frame_width + BORDER_TOLERANCE) &&
      page_point.y.between?(-BORDER_TOLERANCE, @frame_height + BORDER_TOLERANCE)
  end

  # Whether the chosen zoom's coverage holds the whole requested area. False means part of
  # the area has no tiles, so the map will have a blank part there.
  def fully_covered?
    @coverage.fetch(@zoom).contains?(@requested_area)
  end

  # The tiles that exist and show within the frame, from the top row down and left to
  # right, so the PDF's contents stay in a stable order. Tiles can hang over the frame's
  # border, so FlyerMapPage clips them.
  def tiles
    @tiles ||= begin
      half_width = @frame_width / (2 * @scale)
      half_height = @frame_height / (2 * @scale)
      coverage = coverage_tile_ranges
      columns = overlap_of(
        tile_range(@frame_centre.x - half_width, @frame_centre.x + half_width), coverage[:x]
      )
      rows = overlap_of(
        tile_range(@frame_centre.y - half_height, @frame_centre.y + half_height), coverage[:y]
      )
      rows.to_a.product(columns.to_a).map { |row, column| tile_at(column, row) }.freeze
    end
  end

  private

  def parse_coverage(manifest)
    fields = manifest.to_h.symbolize_keys
    allowed = fields.fetch(:min_zoom)..fields.fetch(:max_zoom)
    coverage = fields.fetch(:zooms).to_h
      .to_h { |zoom, bounds| [zoom.to_s.to_i, bounds] }
      .select { |zoom, _bounds| allowed.cover?(zoom) }
      .transform_values { |bounds| Bounds.from(bounds) }
    raise ArgumentError, "the manifest lists no usable zooms" if coverage.empty?

    coverage
  end

  # The rectangle in degrees that holds a circle around the centre. Measuring in km rather
  # than world pixels matters, because a km takes up more world pixels further north. In
  # Victoria it's about 1.5 times as many as at the equator.
  #
  # One radian of the Earth's surface is EARTH_RADIUS_KM long, which gives the circle's
  # size as an angle. North and south simply add that angle to the latitude. The widest
  # east-west reach of a circle on a sphere is asin(sin(angle) / cos(lat)). It's used
  # instead of angle / cos(lat) because that shortcut comes up short for large circles. If
  # the circle reaches a pole it surrounds every longitude, so the reach is the full 180.
  def area_around(centre, radius_km)
    angle = radius_km.to_f / GeoPoint::EARTH_RADIUS_KM
    angle_degrees = angle * 180 / Math::PI
    north = centre.lat + angle_degrees
    south = centre.lat - angle_degrees
    reach = east_west_reach(centre.lat, angle, reaches_pole: north >= 90 || south <= -90)

    Bounds.new(south: [south, -90].max, west: centre.lng - reach, north: [north, 90].min, east: centre.lng + reach)
  end

  def east_west_reach(lat, angle, reaches_pole:)
    ratio = Math.sin(angle) / Math.cos(lat * Math::PI / 180)
    return 180.0 if reaches_pole || ratio >= 1

    Math.asin(ratio) * 180 / Math::PI
  end

  # Picks a zoom in up to three stages. Zooms are tried from most to least detailed.
  #
  # First it keeps those where the requested area fits at a readable size. If there are
  # none, the area is too big for any zoom, so only the least detailed is left to try.
  #
  # Next it takes the first of those whose coverage holds the whole area. This is how a
  # request outside the urban core falls back from zoom 16 to zoom 15.
  #
  # If none do, the area runs past the tiles. We don't fail, because a guide should still
  # print. It takes the zoom showing the most of the area, and then the most detailed. Going
  # straight to the most detailed could pick zoom 16, showing just a scrap of the urban core
  # when zoom 14 would have shown most of the area.
  def choose_zoom
    most_detailed_first = @coverage.keys.sort.reverse
    readable = most_detailed_first.select { |zoom| fit_scale(zoom) >= MIN_SCALE }
    candidates = readable.empty? ? [most_detailed_first.last] : readable

    candidates.find { |zoom| @coverage.fetch(zoom).contains?(@requested_area) } ||
      candidates.max_by { |zoom| [covered_share(@coverage.fetch(zoom)), zoom] }
  end

  # The scale at which the requested area exactly fills the frame's tighter direction. It
  # measures from the frame's centre outward on each side, which is what keeps the area
  # inside: Mercator stretches the north half of a circle more than the south half, so a
  # centred circle isn't centred in its own world-pixel rectangle.
  #
  # An area with no size divides by zero, which gives Infinity for floats. That's the right
  # answer here, because anything fits, and the caller's MAX_SCALE limit then applies.
  def fit_scale(zoom)
    centre = world_centre_at(zoom)
    area = world_rectangle(@requested_area, zoom)
    half_width = [centre.x - area[:left], area[:right] - centre.x].max
    half_height = [centre.y - area[:top], area[:bottom] - centre.y].max

    [@frame_width / (2 * half_width), @frame_height / (2 * half_height)].min
  end

  # The world position at the frame's centre: the given centre, or else the middle of the
  # bounds. For bounds, the middle is taken in world pixels because that's what centres
  # them on the page. Averaging the latitudes would give a different, off-centre answer.
  def world_centre_at(zoom)
    return MapProjection.to_world(@given_centre, zoom) if @given_centre

    area = world_rectangle(@requested_area, zoom)
    MapProjection::WorldPoint.new(x: (area[:left] + area[:right]) / 2, y: (area[:top] + area[:bottom]) / 2)
  end

  # What share of the requested area (0 to 1) a zoom's coverage holds. It's measured at
  # zoom 0 because a share comes out the same at any zoom.
  def covered_share(coverage)
    requested = world_rectangle(@requested_area, 0)
    available = world_rectangle(coverage, 0)
    width = [requested[:right], available[:right]].min - [requested[:left], available[:left]].max
    height = [requested[:bottom], available[:bottom]].min - [requested[:top], available[:top]].max
    return 0.0 unless width.positive? && height.positive?

    width * height / ((requested[:right] - requested[:left]) * (requested[:bottom] - requested[:top]))
  end

  # An area's edges in world pixels. North is the top because world y grows downward.
  def world_rectangle(bounds, zoom)
    corner_nw = MapProjection.to_world(GeoPoint.new(lat: bounds.north, lng: bounds.west), zoom)
    corner_se = MapProjection.to_world(GeoPoint.new(lat: bounds.south, lng: bounds.east), zoom)
    {left: corner_nw.x, top: corner_nw.y, right: corner_se.x, bottom: corner_se.y}
  end

  # The one mapping from world pixels to the page, used by both pins and tiles. Measure from
  # the frame's centre, scale it, then move to the frame's centre on the page. The y line
  # subtracts because world y grows downward and page y grows upward.
  def page_position_for_world(world)
    PagePoint.new(
      x: (world.x - @frame_centre.x) * @scale + @frame_width / 2,
      y: @frame_height / 2 - (world.y - @frame_centre.y) * @scale
    )
  end

  def tile_at(column, row)
    size = MapProjection::TILE_SIZE
    corner = page_position_for_world(MapProjection::WorldPoint.new(x: column * size, y: row * size))
    Tile.new(z: @zoom, x: column, y: row, left: corner.x, top: corner.y, size: size * @scale)
  end

  # Which tile numbers exist at this zoom, per the manifest. A tile only counts if it overlaps
  # the coverage by more than a line, so a bound exactly on a tile's edge doesn't ask for a
  # neighbouring tile that the tile builder may not have made.
  def coverage_tile_ranges
    corners = world_rectangle(@coverage.fetch(@zoom), @zoom)
    last = 2**@zoom - 1
    {
      x: overlap_of(tile_range(corners[:left], corners[:right]), 0..last),
      y: overlap_of(tile_range(corners[:top], corners[:bottom]), 0..last)
    }
  end

  # The tile numbers touching a stretch of world pixels. Floor finds the tile holding the
  # start. The end uses ceil minus one because a stretch ending exactly on a tile's edge
  # doesn't reach into the next tile, so tiles that only touch the frame get skipped.
  def tile_range(from, to)
    size = MapProjection::TILE_SIZE
    (from / size).floor..((to / size).ceil - 1)
  end

  def overlap_of(first, second)
    [first.begin, second.begin].max..[first.end, second.end].min
  end
end
