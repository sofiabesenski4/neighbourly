require "prawn"

# A measured, row-based layout. Cards stay at the agreed text sizes;
# narrow and full-width measurements are cached for the duration of a render.
# A card that exceeds a full page continues across pages without losing text.
# Each resource gets one number for the guide, shown on its card and its pin on the final
# map page, which FlyerMapPage draws. See docs/printed-map.md.
class FlyerPdf
  MARGIN = 43.2
  GUTTER = 20.16
  GAP = 12
  PADDING = 10
  BODY_SIZE = 11.5
  TITLE_SIZE = 13.5
  SECONDARY_SIZE = 10.5
  BOTTOM = 6
  # One resource's card. number is its one number for the whole guide, which its map pin also
  # shows. heading is what the card's header prints, and title stays the plain name for lists.
  Entry = Data.define(:key, :number, :title, :rows) do
    def heading
      "#{number}. #{title}"
    end
  end
  Measure = Data.define(:height, :header_height, :row_heights)

  def initialize(sections:, origin: nil, printed_at: Time.current)
    @sections = sections
    @origin = origin
    @printed_at = printed_at
    @pdf = Prawn::Document.new(page_size: "LETTER", margin: MARGIN, compress: true)
    fonts = Rails.root.join("app/assets/fonts/dejavu")
    @pdf.font_families.update("ResourceSans" => {
      normal: fonts.join("DejaVuSans.ttf").to_s,
      bold: fonts.join("DejaVuSans-Bold.ttf").to_s
    })
    @pdf.font("ResourceSans", size: BODY_SIZE)
    @width = @pdf.bounds.width
    @column_width = (@width - GUTTER) / 2
    @measurements = {}
    @started = false
  end

  def render
    new_page
    @sections.each do |section|
      render_section(section) if section.resources.any?
    end
    render_map if entries.any?
    @pdf.number_pages("Printed #{@printed_at.strftime("%Y-%m-%d %H:%M %Z")}  |  Page <page>",
      at: [0, -16], width: @width, size: 9.5)
    @pdf.render
  end

  private

  def clean(value)
    value.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      .gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/, "")
  end

  def key_for(document)
    document.id || document.object_id
  end

  def entry_for(document)
    entries.fetch(key_for(document))
  end

  # Every resource's entry, numbered in the order the cards print. A resource in two
  # categories prints two cards, and both share its one entry and number, so the same pin
  # matches both.
  def entries
    @entries ||= @sections.flat_map(&:resources).uniq { |document| key_for(document) }
      .each_with_index.to_h { |document, index| [key_for(document), build_entry(document, index + 1)] }
  end

  def render_map
    new_page
    draw_heading("Map")
    @pdf.move_cursor_to(@cursor)
    FlyerMapPage.new(@pdf, items: map_items, centre: (@origin.point if @origin&.located?)).draw
  end

  def map_items
    @sections.flat_map(&:resources).uniq { |document| key_for(document) }.map do |document|
      entry = entry_for(document)
      MapPinLayout::Item.new(number: entry.number, title: entry.title, point: document.coordinates)
    end
  end

  def build_entry(document, number)
    card = ResourceCard.new(document, origin: @origin)
    title = clean(card.title)
    rows = card.fields.map { |field|
      {label: clean(field[:label]), value: clean(field[:value]),
       size: ["Last updated", "Information source"].include?(field[:label]) ? SECONDARY_SIZE : BODY_SIZE}
    }
    # Keep an unusually long name in the body, where it can continue across
    # pages, rather than repeating an oversized header on every page.
    if @pdf.height_of(title, width: @column_width - 2 * PADDING, size: TITLE_SIZE, style: :bold) > 80
      rows.unshift({label: "Resource name", value: title, size: BODY_SIZE})
      title = title.each_grapheme_cluster.take(80).join + "…"
    end
    Entry.new(key: key_for(document), number: number, title: title, rows: rows)
  end

  def fragments(row)
    [{text: "#{row[:label]}: ", styles: [:bold], size: row[:size]},
      {text: row[:value], size: row[:size]}]
  end

  def measurement(entry, width)
    @measurements[[entry.key, width]] ||= begin
      inner = width - 2 * PADDING
      header = @pdf.height_of(entry.heading, width: inner, size: TITLE_SIZE, style: :bold, leading: 2) + 16
      heights = entry.rows.map { |row| @pdf.height_of_formatted(fragments(row), width: inner, leading: 2) }
      Measure.new(height: header + 2 * PADDING + heights.sum + [heights.size - 1, 0].max * 5,
        header_height: header, row_heights: heights)
    end
  end

  def new_page
    first_page = !@started
    @pdf.start_new_page if @started
    @started = true
    @pdf.text("Greater Victoria resource guide", size: 23, style: :bold)
    if first_page && @origin
      @pdf.move_down(4)
      @pdf.text(origin_note, size: SECONDARY_SIZE)
    end
    @pdf.move_down(12)
    @cursor = @page_top = @pdf.cursor
  end

  # Says what the distances on the cards mean, or why they're missing. Without this,
  # a reader couldn't tell what the numbers are measured from, or that a guide with
  # no distances wasn't what the person asked for.
  def origin_note
    place = clean(@origin.label)
    if @origin.located?
      "Distances are from #{place}, in a straight line. Walking times are estimates that " \
        "allow for following streets at about 5 km/h, and some routes may take longer."
    else
      "Distances aren't shown because we couldn't look up #{place} when this was " \
        "printed. Please try again later."
    end
  end

  def heading_height(label)
    @pdf.height_of(label, width: @width, size: 18, style: :bold) + 8
  end

  def draw_heading(label)
    height = heading_height(label)
    @pdf.text_box(label, at: [0, @cursor], width: @width, height: height, size: 18, style: :bold)
    @cursor -= height
  end

  def draw_next_row(remaining)
    first = remaining.first
    second = remaining[1]
    available = @cursor - BOTTOM
    first_narrow = measurement(first, @column_width).height
    second_narrow = measurement(second, @column_width).height if second

    if second && first_narrow <= available && second_narrow <= available
      draw_card(first, 0, @cursor, @column_width)
      draw_card(second, @column_width + GUTTER, @cursor, @column_width)
      @cursor -= [first_narrow, second_narrow].max + GAP
      remaining.shift(2)
    else
      wide_height = measurement(first, @width).height
      raise "Unable to place a resource card" if wide_height > available

      draw_card(first, 0, @cursor, @width)
      @cursor -= wide_height + GAP
      remaining.shift
    end
  end

  def render_section(section)
    remaining = section.resources.map { |document| entry_for(document) }
    continued = false
    heading_pending = true
    while remaining.any?
      label = section.name + (continued ? " continued" : "")
      available = @cursor - BOTTOM - (heading_pending ? heading_height(label) : 0)
      unless measurement(remaining.first, @width).height <= available
        if @cursor == @page_top
          draw_heading(label) if heading_pending
          render_oversized(remaining.shift, section.name)
          heading_pending = false
          continued = true
        else
          new_page
          heading_pending = true
        end
        next
      end
      if heading_pending
        draw_heading(label)
        heading_pending = false
      end
      draw_next_row(remaining)
      continued = true
    end
    @cursor -= 8
  end

  def frame(title, x, top, width, height, header_height)
    @pdf.fill_color("EFEFEF")
    @pdf.fill_rectangle([x, top], width, header_height)
    @pdf.stroke_color("B4B4B4")
    @pdf.line_width(0.6)
    @pdf.stroke_rectangle([x, top], width, height)
    @pdf.stroke_line([x, top - header_height], [x + width, top - header_height])
    @pdf.fill_color("000000")
    @pdf.text_box(title, at: [x + PADDING, top - 8], width: width - 2 * PADDING,
      height: header_height, size: TITLE_SIZE, style: :bold, leading: 2)
  end

  def draw_card(entry, x, top, width)
    measure = measurement(entry, width)
    frame(entry.heading, x, top, width, measure.height, measure.header_height)
    y = top - measure.header_height - PADDING
    entry.rows.each_with_index do |row, index|
      height = measure.row_heights[index]
      leftover = @pdf.formatted_text_box(fragments(row), at: [x + PADDING, y],
        width: width - 2 * PADDING, height: height + 0.5, leading: 2)
      raise "A resource field did not fit its measured height" if leftover.any?
      y -= height + 5
    end
  end

  def render_oversized(entry, category_name)
    remaining = entry.rows.flat_map { |row| fragments(row) + [{text: "\n\n", size: row[:size]}] }
    part = 0
    while remaining.any?
      title = entry.heading + (part.positive? ? " continued" : "")
      header = @pdf.height_of(title, width: @width - 2 * PADDING, size: TITLE_SIZE, style: :bold, leading: 2) + 16
      available = @cursor - BOTTOM - header - 2 * PADDING
      options = {at: [PADDING, @cursor - header - PADDING], width: @width - 2 * PADDING,
                 height: available, leading: 2, document: @pdf}
      box = Prawn::Text::Formatted::Box.new(remaining.map(&:dup), options)
      leftover = box.render(dry_run: true)
      raise "An oversized resource field could not be laid out" if box.height.zero? || leftover == remaining
      height = header + 2 * PADDING + box.height
      frame(title, 0, @cursor, @width, height, header)
      @pdf.formatted_text_box(remaining.map(&:dup), options.except(:document))
      @cursor -= height + GAP
      remaining = leftover
      if remaining.any?
        new_page
        draw_heading("#{category_name} continued")
      end
      part += 1
    end
  end
end
