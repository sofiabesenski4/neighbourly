# Decides what to draw for each numbered resource on a printed map: a pin, an arrow at the
# map's edge, or an entry in the "not shown on map" list.
#
# Architecture: the PDF step gives this a MapView and the guide's numbered resources, then
# draws the plain values it returns. It uses MapView for all positions, so pins stay lined
# up with the tiles. It knows nothing about Prawn or the database.
#
# Why it exists: it keeps these choices out of the drawing code, where they'd be hard to
# test. It also makes a guide's map come out the same each time. Everything is put in order
# by number first, so the order resources arrive in can't change the result.
#
# Usage:
#   items = [MapPinLayout::Item.new(number: 3, title: "Our Place", point: geo_point)]
#   layout = MapPinLayout.new(view, items)
#   layout.pins          # MapPinLayout::Pin values, such as a label of "3, 7"
#   layout.edge_markers  # MapPinLayout::EdgeMarker values
#   layout.not_shown     # MapPinLayout::NotShown values
class MapPinLayout
  # All three sizes are in page points, and assume a pin about 14 points wide and an edge
  # marker about 28 points wide. Those sizes are estimates, because the drawing step hasn't
  # been written. If it draws them much larger or smaller, these should change to match.

  # Pins closer than this share one pin. Pins this close overlap so much that their digits
  # would print on top of each other. It's a bit under half a pin's width. Pins further
  # apart overlap partly, but both numbers can still be made out.
  PIN_MERGE_DISTANCE = 6.0

  # How far inside the border the middle of an edge marker sits. It's half the marker's
  # width, which keeps the whole marker inside the frame.
  EDGE_MARKER_INSET = 14.0

  # Edge markers closer than this share one marker. It's one full marker's width, the
  # distance at which two markers would begin to touch.
  EDGE_MARKER_MERGE_DISTANCE = 28.0

  # One resource to place. Point is a GeoPoint or nil.
  Item = Data.define(:number, :title, :point)

  # A pin for one or more resources. Numbers and titles are in the same order. x and y are
  # page points from the frame's bottom-left corner.
  class Pin < Data.define(:x, :y, :numbers, :titles)
    def label
      numbers.join(", ")
    end
  end

  # An arrow at the frame's edge for one or more resources that are off the map.
  #
  # angle_degrees is measured counterclockwise from pointing right, so 0 is east, 90 is
  # north, 180 is west and 270 is south. That's the direction Prawn's `rotate` turns, so
  # the value can be passed straight to it.
  #
  # min_km and max_km are the nearest and furthest of its resources, measured in a straight
  # line from the map's centre. They're equal when there's one resource.
  class EdgeMarker < Data.define(:x, :y, :angle_degrees, :numbers, :titles, :min_km, :max_km)
    def label
      numbers.join(", ")
    end

    # Like "4.4 km" or "2.1–4.5 km". One decimal place matches the printed cards.
    def distance_label
      near = format("%.1f", min_km)
      far = format("%.1f", max_km)
      (near == far) ? "#{near} km" : "#{near}–#{far} km"
    end
  end

  # A resource with no usable coordinates, for the list printed beside the map.
  NotShown = Data.define(:number, :title)

  # A resource on its way to becoming a pin or marker. x and y are where it would be drawn.
  # For an off-map resource, right and up are the direction to it from the frame's centre.
  Placement = Data.define(:item, :x, :y, :right, :up)
  private_constant :Placement

  attr_reader :pins, :edge_markers, :not_shown

  # Items need number, title and point, and any object with those three will do.
  def initialize(view, items)
    @view = view
    @frame_centre_x = view.frame_width / 2
    @frame_centre_y = view.frame_height / 2

    unique = unique_by_number(items)
    plottable, unplottable = unique.partition { |item| plottable?(item.point) }
    on_map, off_map = plottable.partition { |item| view.inside_frame?(view.page_position(item.point)) }

    @pins = build_pins(on_map).freeze
    @edge_markers = build_edge_markers(off_map).freeze
    @not_shown = unplottable.map { |item| NotShown.new(number: item.number, title: item.title) }.freeze
  end

  private

  # A resource printed under two categories can arrive twice with the same number. It's kept
  # once, preferring a copy that has coordinates. The title and coordinates then settle any
  # remaining tie, so the input's order can't change which copy wins.
  def unique_by_number(items)
    items.group_by(&:number)
      .map { |_number, copies| copies.min_by { |copy| preference(copy) } }
      .sort_by(&:number)
  end

  def preference(item)
    return [1, item.title.to_s, 0.0, 0.0] unless plottable?(item.point)

    [0, item.title.to_s, item.point.lat.to_f, item.point.lng.to_f]
  end

  # Whether a point is a real place. Imports only check that coordinates are numbers, so
  # a latitude of 999 can reach this. Projecting it would give a confident marker pointing
  # at nowhere, so it's listed as not shown instead. The finite check comes first because
  # between? raises an error on NaN.
  def plottable?(point)
    return false if point.nil?
    return false unless [point.lat, point.lng].all? { |value| value.is_a?(Numeric) && value.to_f.finite? }

    point.lat.between?(-90, 90) && point.lng.between?(-180, 180)
  end

  def build_pins(items)
    placements = items.map do |item|
      position = @view.page_position(item.point)
      Placement.new(item: item, x: position.x, y: position.y, right: 0.0, up: 0.0)
    end

    # The middle of the group is the fairest spot. It's within PIN_MERGE_DISTANCE of every
    # resource in the group, so a merged pin stays close to each real location.
    group_nearby(placements, PIN_MERGE_DISTANCE).map do |group|
      Pin.new(
        x: group.sum(&:x) / group.size,
        y: group.sum(&:y) / group.size,
        numbers: group.map { |placement| placement.item.number }.freeze,
        titles: group.map { |placement| placement.item.title }.freeze
      )
    end
  end

  def build_edge_markers(items)
    placements = items.map do |item|
      position = @view.page_position(item.point)
      right = position.x - @frame_centre_x
      up = position.y - @frame_centre_y
      x, y = edge_position(right, up)
      Placement.new(item: item, x: x, y: y, right: right, up: up)
    end

    group_nearby(placements, EDGE_MARKER_MERGE_DISTANCE).map { |group| edge_marker_for(group) }
  end

  # Merges a group's directions by adding together arrows of equal length. Averaging the
  # angles as numbers would be wrong across east: 1 and 359 degrees are both nearly east,
  # but average to 180, which is west. Equal lengths also stop a distant resource from
  # outweighing a near one. Then the marker is placed on the line for the merged direction,
  # so its arrow still points straight out from the map's centre.
  def edge_marker_for(group)
    right, up = merged_direction(group)
    x, y = edge_position(right, up)
    distances = group.map { |placement| @view.centre.distance_km_to(placement.item.point) }

    EdgeMarker.new(
      x: x,
      y: y,
      angle_degrees: angle_of(right, up),
      numbers: group.map { |placement| placement.item.number }.freeze,
      titles: group.map { |placement| placement.item.title }.freeze,
      min_km: distances.min,
      max_km: distances.max
    )
  end

  # Opposite arrows cancel out, leaving no direction. That needs a frame smaller than a
  # marker, so it won't really happen, but the first resource's direction is a safe answer.
  def merged_direction(group)
    right = group.sum { |placement| placement.right / Math.hypot(placement.right, placement.up) }
    up = group.sum { |placement| placement.up / Math.hypot(placement.right, placement.up) }
    return [right, up] if Math.hypot(right, up) > 1e-9

    [group.first.right, group.first.up]
  end

  # Where the line from the frame's centre in this direction meets a rectangle set in from
  # the border by the inset. We walk along the line until we hit the first side: the walk
  # to the left or right sides is space_across / |right|, and to the top or bottom sides is
  # space_up / |up|. The smaller walk is the side reached first.
  #
  # Using the inset rectangle, not moving the border crossing inward afterwards, keeps the
  # marker exactly on the line. The line can be straight up or sideways, so a zero in that
  # direction means that side is never reached. A frame smaller than a marker has no space
  # left, so the marker sits at the centre rather than outside the frame.
  def edge_position(right, up)
    space_across = [@frame_centre_x - EDGE_MARKER_INSET, 0.0].max
    space_up = [@frame_centre_y - EDGE_MARKER_INSET, 0.0].max
    walks = []
    walks << space_across / right.abs unless right.zero?
    walks << space_up / up.abs unless up.zero?
    walk = walks.min || 0.0

    [@frame_centre_x + right * walk, @frame_centre_y + up * walk]
  end

  # The angle of a direction, counterclockwise from pointing right. atan2 gives -180 to 180
  # and the % turns that into 0 up to 360. Rounding first removes rounding noise, which
  # could otherwise turn a tiny negative angle into 359.9999 rather than 0.
  def angle_of(right, up)
    (Math.atan2(up, right) * 180 / Math::PI).round(6) % 360
  end

  # Sorts placements into groups, going through them in number order. A placement joins the
  # first group where it's within max_distance of EVERY member, otherwise it starts a new
  # group. Because groups are created in number order, they stay sorted by first number.
  #
  # Requiring every member prevents chaining, where a line of pins each near the next would
  # become one pin far from the resources at its ends. That's likely downtown. The cost is
  # that two pins just over the limit stay separate and overlap somewhat.
  #
  # Resources at the same spot always end up together. Their distances to everything are
  # identical, so a group that turned away the first also turns away the second, and the
  # group the first joined still has room for the second.
  def group_nearby(placements, max_distance)
    placements.each_with_object([]) do |placement, groups|
      group = groups.find do |candidate|
        candidate.all? { |other| Math.hypot(other.x - placement.x, other.y - placement.y) <= max_distance }
      end
      group ? group << placement : groups << [placement]
    end
  end
end
