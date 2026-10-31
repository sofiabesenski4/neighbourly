require "prawn"

# A measured, row-based layout. Cards stay at the agreed text sizes;
# narrow and full-width measurements are cached for the duration of a render.
# A card that exceeds a full page continues across pages without losing text.
class FlyerPdf
  MARGIN = 43.2
  GUTTER = 20.16
  GAP = 12
  PADDING = 10
  BODY_SIZE = 11.5
  TITLE_SIZE = 13.5
  SECONDARY_SIZE = 10.5
  BOTTOM = 6
  Entry = Data.define(:key, :title, :rows)
  Measure = Data.define(:height, :header_height, :row_heights)

  def initialize(sections:, printed_at: Time.current)
    @sections = sections
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
    @pdf.number_pages("Printed #{@printed_at.strftime("%Y-%m-%d %H:%M %Z")}  |  Page <page>",
      at: [0, -16], width: @width, size: 9.5)
    @pdf.render
  end

  private

  def clean(value)
    value.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      .gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/, "")
  end

  def entry_for(document)
    card = ResourceCard.new(document)
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
    Entry.new(key: document.id || document.object_id, title: title, rows: rows)
  end

  def fragments(row)
    [{text: "#{row[:label]}: ", styles: [:bold], size: row[:size]},
      {text: row[:value], size: row[:size]}]
  end

  def measurement(entry, width)
    @measurements[[entry.key, width]] ||= begin
      inner = width - 2 * PADDING
      header = @pdf.height_of(entry.title, width: inner, size: TITLE_SIZE, style: :bold, leading: 2) + 16
      heights = entry.rows.map { |row| @pdf.height_of_formatted(fragments(row), width: inner, leading: 2) }
      Measure.new(height: header + 2 * PADDING + heights.sum + [heights.size - 1, 0].max * 5,
        header_height: header, row_heights: heights)
    end
  end

  def new_page
    @pdf.start_new_page if @started
    @started = true
    @pdf.text("Greater Victoria resource guide", size: 23, style: :bold)
    @pdf.move_down(12)
    @cursor = @page_top = @pdf.cursor
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
      label = section.category.name + (continued ? " continued" : "")
      available = @cursor - BOTTOM - (heading_pending ? heading_height(label) : 0)
      unless measurement(remaining.first, @width).height <= available
        if @cursor == @page_top
          draw_heading(label) if heading_pending
          render_oversized(remaining.shift, section.category.name)
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
    frame(entry.title, x, top, width, measure.height, measure.header_height)
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
      title = entry.title + (part.positive? ? " continued" : "")
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
