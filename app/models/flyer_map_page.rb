# Draws the map at the end of a printed guide: the tiles, a numbered pin for each resource,
# a scale bar, the required credit, and a list of resources with no known location.
#
# Architecture: FlyerPdf owns the document and the resource numbers, and hands this class
# its Prawn document and a list of items once the cards are done. MapView decides what the
# map shows, MapPinLayout decides what becomes a pin, and MapTileSet finds the files. This
# class only turns their answers into marks on the page, and it makes no network calls.
#
# Why it's separate from FlyerPdf: FlyerPdf lays out rows of cards, and nothing here shares
# that logic. See docs/printed-map.md for how the whole map works.
class FlyerMapPage
  # Where the map centres when there's no chosen location: the middle of downtown Victoria.
  DOWNTOWN = GeoPoint.new(lat: 48.4265, lng: -123.3656)

  # How far the map must reach from its centre. It isn't something the user picks. Chosen by
  # looking at printouts: this is about the largest radius that still fits at zoom 15, where
  # most street names appear. At 1.5 km the map drops to zoom 14, which has few of them.
  RADIUS_KM = 1.3

  # A long list of resources shrinks the map, down to this height in points. Past that the
  # list continues on another page, because a shorter map becomes too small to read.
  MIN_MAP_HEIGHT = 400

  # MapPinLayout's merge distances assume this pin size, so change them together.
  PIN_DIAMETER = 14
  PIN_TEXT_SIZE = 8
  PIN_SIDE_PADDING = 3

  SCALE_ROW_HEIGHT = 18
  SCALE_BAR_HEIGHT = 3
  LIST_SIZE = 9.5
  CREDIT_SIZE = 6.5
  GAP = 6

  # items are MapPinLayout::Item values. centre is a GeoPoint, or nil for downtown.
  def initialize(pdf, items:, centre: nil, tile_set: MapTileSet.default)
    @pdf = pdf
    @items = items
    @centre = centre || DOWNTOWN
    @tile_set = tile_set
    @width = pdf.bounds.width
  end

  # Draws from the document's cursor downward.
  def draw
    layout = MapPinLayout.new(view_with_height(@pdf.cursor), @items)
    view = view_with_height(map_height(layout.not_shown))
    layout = MapPinLayout.new(view, @items)

    @pdf.bounding_box([0, @pdf.cursor], width: view.frame_width, height: view.frame_height) do
      draw_tiles(view)
      draw_border(view)
      layout.pins.each { |pin| draw_pin(pin) }
    end
    draw_scale(view)
    draw_credit
    draw_not_shown(layout.not_shown)
  end

  private

  # A location with no tiles at all would give an empty box, so the map shows downtown
  # instead, where most resources are. A location partly on the tiles keeps its own map.
  def view_with_height(height)
    view = build_view(@centre, height)
    view.tiles.empty? ? build_view(DOWNTOWN, height) : view
  end

  def build_view(centre, height)
    MapView.new(frame_width: @width, frame_height: height, manifest: @tile_set.view_manifest,
      centre: centre, radius_km: RADIUS_KM)
  end

  # The map takes whatever the text below it leaves.
  def map_height(not_shown)
    below = GAP + SCALE_ROW_HEIGHT + credit_height + not_shown_height(not_shown)

    [@pdf.cursor - below, MIN_MAP_HEIGHT].max
  end

  # Tiles hang over the frame's border, so they're clipped to it. Prawn has no public clip,
  # so this writes the PDF operators directly: `re` describes a rectangle, `W` makes it the
  # clipping area, and `n` ends the path without drawing it. Clipping lasts until the
  # graphics state is restored, which keeps it from affecting anything drawn afterward. The
  # rectangle uses absolute page positions because raw operators ignore Prawn's bounds.
  def draw_tiles(view)
    left = @pdf.bounds.absolute_left
    bottom = @pdf.bounds.absolute_bottom

    @pdf.save_graphics_state do
      @pdf.renderer.add_content("#{left} #{bottom} #{view.frame_width} #{view.frame_height} re W n")
      view.tiles.each do |tile|
        path = @tile_set.path_for(tile)
        @pdf.image(path, at: [tile.left, tile.top], width: tile.size, height: tile.size) if path
      end
    end
  end

  def draw_border(view)
    @pdf.stroke_color("808080")
    @pdf.line_width(0.6)
    @pdf.stroke_rectangle([0, view.frame_height], view.frame_width, view.frame_height)
    @pdf.stroke_color("000000")
  end

  # A black pin with white text, centred on the place, because the map is grey and the page
  # may be photocopied. Colour wouldn't survive that. A single number gets a circle, and a
  # longer label stretches it into a pill. The white outline separates overlapping pins.
  def draw_pin(pin)
    label = pin.label
    width = [text_width(label) + 2 * PIN_SIDE_PADDING, PIN_DIAMETER].max
    corner = [pin.x - width / 2.0, pin.y + PIN_DIAMETER / 2.0]

    @pdf.fill_color("000000")
    @pdf.stroke_color("FFFFFF")
    @pdf.line_width(0.75)
    @pdf.fill_and_stroke_rounded_rectangle(corner, width, PIN_DIAMETER, PIN_DIAMETER / 2.0)
    @pdf.fill_color("FFFFFF")
    # 0.36 of the text size is about half the height of a digit, which centres it vertically.
    @pdf.draw_text(label, at: [pin.x - text_width(label) / 2.0, pin.y - PIN_TEXT_SIZE * 0.36],
      size: PIN_TEXT_SIZE, style: :bold)
    @pdf.fill_color("000000")
    @pdf.stroke_color("000000")
  end

  def text_width(label)
    @pdf.width_of(label, size: PIN_TEXT_SIZE, style: :bold)
  end

  # The bar is exactly one km at the map's centre. The minutes come from the same figures as
  # the cards, so the scale and the cards can't disagree.
  def draw_scale(view)
    minutes = (ResourceCard::STREET_ROUTE_FACTOR * ResourceCard::WALKING_MINUTES_PER_KM).round
    length = view.points_per_km
    top = @pdf.cursor - GAP

    @pdf.fill_rectangle([0, top - 3], length, SCALE_BAR_HEIGHT)
    @pdf.draw_text("1 km ≈ #{minutes} min walk", at: [length + GAP, top - 7], size: LIST_SIZE)
    @pdf.move_cursor_to(top - SCALE_ROW_HEIGHT)
  end

  def draw_credit
    @pdf.text(credit, size: CREDIT_SIZE)
  end

  # OpenStreetMap's licence asks for the credit near the map. The style's CC BY licence only
  # asks for one somewhere readers can find it, and this is the obvious place for both.
  def credit
    "#{@tile_set.attribution}. #{@tile_set.style_credit}"
  end

  def credit_height
    @pdf.height_of(credit, width: @width, size: CREDIT_SIZE)
  end

  # Runs on as one paragraph, so a long list takes little space and can continue on the next
  # page by itself.
  def draw_not_shown(not_shown)
    return if not_shown.empty?

    @pdf.move_down(GAP)
    @pdf.formatted_text(not_shown_fragments(not_shown))
  end

  def not_shown_height(not_shown)
    return 0 if not_shown.empty?

    GAP + @pdf.height_of_formatted(not_shown_fragments(not_shown), width: @width)
  end

  def not_shown_fragments(not_shown)
    names = not_shown.map { |resource| "#{resource.number}. #{resource.title}" }.join("; ")
    [{text: "Not shown on map: ", styles: [:bold], size: LIST_SIZE}, {text: names, size: LIST_SIZE}]
  end
end
