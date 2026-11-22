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
  PAGE_HEADER_HEIGHT = 32
  GOLD = "CB800E"
  INK = "000000"
  SECTION_TITLE_SIZE = 19
  SECTION_INSET = 16
  SECTION_GAP = 9
  SECTION_LINE_WIDTH = 2.25
  CARD_RADIUS = 14
  # One resource's card. number is its one number for the whole guide, which its map pin also
  # shows. heading is what the card's header prints, and title stays the plain name for lists.
  Entry = Data.define(:key, :number, :title, :rows) do
    def heading
      "#{number}. #{title}"
    end
  end
  Measure = Data.define(:height, :header_height, :row_heights)

  def self.draw_page_header(pdf)
    pdf.canvas do
      top = pdf.bounds.top - MARGIN
      right = pdf.bounds.right - MARGIN
      pdf.fill_color("1A1A1A")
      pdf.text_box("NEIGHBOURLY RESOURCE GUIDE", at: [MARGIN, top], width: right - MARGIN,
        height: 15, size: 9.75, style: :bold, character_spacing: 1)
      if pdf.page_number == 2
        pdf.stroke_color(GOLD)
        pdf.line_width(3)
        pdf.stroke_horizontal_line(MARGIN, right, at: top - 18)
      end
    end
  end

  def initialize(sections:, origin: nil, printed_at: Time.current, detail_level: "detailed", site_url: nil)
    @sections = sections.reject { |section| section.resources.empty? }
    @origin = origin
    @printed_at = printed_at
    @detail_level = detail_level
    @pdf = Prawn::Document.new(page_size: "LETTER", margin: MARGIN, compress: true)
    fonts = Rails.root.join("app/assets/fonts/dejavu")
    @pdf.font_families.update("ResourceSans" => {
      normal: fonts.join("DejaVuSans.ttf").to_s,
      bold: fonts.join("DejaVuSans-Bold.ttf").to_s
    })
    @pdf.font("ResourceSans", size: BODY_SIZE)
    @width = @pdf.bounds.width
    @measurements = {}
    @started = false
    @flat_categories = @sections.select { |section| flat_section?(section) }.flat_map(&:resources)
      .to_h { |service| [key_for(service), service.category_names.presence || ["Other resources"]] }
    grouped_categories = @sections.reject { |section| flat_section?(section) }.map(&:name)
    @category_palette = FlyerCategoryPalette.new(grouped_categories + @flat_categories.values.flatten)
    @quick_finder = FlyerQuickFinder.new(@pdf, palette: @category_palette, site_url: site_url)
    @category_pages = Hash.new { |pages, name| pages[name] = [] }
  end

  def render
    render_cover
    @quick_finder.page_count.times { @pdf.start_new_page }
    @pdf.start_new_page(top_margin: MARGIN + PAGE_HEADER_HEIGHT)
    first_listing_page = @pdf.page_number
    new_page
    @sections.each { |section| render_section(section) }
    render_map if entries.any?
    (first_listing_page..@pdf.page_count).each do |page_number|
      @pdf.go_to_page(page_number)
      self.class.draw_page_header(@pdf)
    end
    @quick_finder.draw(@category_pages)
    @pdf.number_pages("Printed #{@printed_at.strftime("%Y-%m-%d %H:%M %Z")}  |  Page <page>",
      at: [0, -16], width: @width, size: 9.5,
      start_count_at: first_listing_page, page_filter: ->(page) { page >= first_listing_page })
    @pdf.render
  end

  private

  def render_cover
    artwork = Rails.root.join("app/assets/images/printouts/start-here.png")
    @pdf.canvas do
      @pdf.image(artwork.to_s, at: [0, @pdf.bounds.top], fit: [@pdf.bounds.width, @pdf.bounds.height])
    end
  end

  def flat_section?(section)
    section.category.nil? && section.label == "Resources"
  end

  def record_category_page(entry)
    names = flat_section?(@active_section) ? @flat_categories.fetch(entry.key) : [@active_section.name]
    names.each do |name|
      pages = @category_pages[name]
      pages << @pdf.page_number unless pages.last == @pdf.page_number
    end
  end

  def clean(value)
    value.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      .gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/, "")
  end

  def key_for(service)
    service.id || service.object_id
  end

  def entry_for(service)
    entries.fetch(key_for(service))
  end

  # Every resource's entry, numbered in the order the cards print. A resource in two
  # categories prints two cards, and both share its one entry and number, so the same pin
  # matches both.
  def entries
    @entries ||= @sections.flat_map(&:resources).uniq { |service| key_for(service) }
      .each_with_index.to_h { |service, index| [key_for(service), build_entry(service, index + 1)] }
  end

  def render_map
    new_page
    draw_heading("Map")
    @pdf.move_cursor_to(@cursor)
    FlyerMapPage.new(@pdf, items: map_items, centre: (@origin.point if @origin&.located?)).draw
  end

  def map_items
    @sections.flat_map(&:resources).uniq { |service| key_for(service) }.map do |service|
      entry = entry_for(service)
      MapPinLayout::Item.new(number: entry.number, title: entry.title, point: service.coordinates)
    end
  end

  def build_entry(service, number)
    card = ResourceCard.new(service, origin: @origin)
    title = clean(card.title)
    fields = (@detail_level == "summary") ? card.summary_fields : card.fields
    rows = fields.map { |field|
      {label: clean(field[:label]), value: clean(field[:value]),
       size: ["Last confirmed", "Last updated", "Information source"].include?(field[:label]) ? SECONDARY_SIZE : BODY_SIZE}
    }
    # Keep an unusually long name in the body, where it can continue across
    # pages, rather than repeating an oversized header on every page.
    if @pdf.height_of(title, width: @column_width - 2 * PADDING, size: TITLE_SIZE, style: :bold) > 80
      rows.unshift({label: "Resource name", value: title, size: BODY_SIZE})
      title = title.each_grapheme_cluster.take(80).join + "…"
    end
    Entry.new(key: key_for(service), number: number, title: title, rows: rows)
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
    finish_section_line
    first_page = !@started
    @pdf.start_new_page if @started
    @started = true
    if first_page && @origin && @detail_level == "detailed"
      @pdf.text(origin_note, size: SECONDARY_SIZE)
      @pdf.move_down(12)
    end
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

  def heading_height(label, inset: 0)
    @pdf.height_of(label, width: @width - inset, size: SECTION_TITLE_SIZE, style: :bold) + SECTION_GAP
  end

  def draw_heading(label, colour: nil)
    inset = colour ? SECTION_INSET : 0
    height = heading_height(label, inset: inset)
    @section_top = @cursor if colour
    @pdf.fill_color(colour || INK)
    @pdf.text_box(label, at: [inset, @cursor], width: @width - inset,
      height: height - SECTION_GAP, size: SECTION_TITLE_SIZE, style: :bold)
    @pdf.fill_color(INK)
    @cursor -= height
  end

  def finish_section_line
    return unless @section_top

    # The row cursor includes a trailing gap after the bottom of the last card.
    height = @section_top - (@cursor + GAP)
    @pdf.save_graphics_state do
      @pdf.fill_color(@section_colour)
      @pdf.fill_rounded_rectangle([0, @section_top], SECTION_LINE_WIDTH, height, SECTION_LINE_WIDTH / 2)
    end
    @section_top = nil
  end

  def draw_next_row(remaining)
    first = remaining.first
    second = remaining[1]
    available = @cursor - BOTTOM
    first_narrow = measurement(first, @column_width).height
    second_narrow = measurement(second, @column_width).height if second

    if second && first_narrow <= available && second_narrow <= available
      record_category_page(first)
      record_category_page(second)
      draw_card(first, @section_left, @cursor, @column_width)
      draw_card(second, @section_left + @column_width + GUTTER, @cursor, @column_width)
      @cursor -= [first_narrow, second_narrow].max + GAP
      remaining.shift(2)
    else
      wide_height = measurement(first, @section_width).height
      raise "Unable to place a resource card" if wide_height > available

      record_category_page(first)
      draw_card(first, @section_left, @cursor, @section_width)
      @cursor -= wide_height + GAP
      remaining.shift
    end
  end

  def render_section(section)
    @active_section = section
    @section_colour = flat_section?(section) ? nil : @category_palette.colour_for(section.name)
    @section_left = @section_colour ? SECTION_INSET : 0
    @section_width = @width - @section_left
    @column_width = (@section_width - GUTTER) / 2
    remaining = section.resources.map { |service| entry_for(service) }
    continued = false
    heading_pending = true
    while remaining.any?
      label = section.name + (continued ? " continued" : "")
      available = @cursor - BOTTOM - (heading_pending ? heading_height(label, inset: @section_left) : 0)
      unless measurement(remaining.first, @section_width).height <= available
        if @cursor == @page_top
          draw_heading(label, colour: @section_colour) if heading_pending
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
        draw_heading(label, colour: @section_colour)
        heading_pending = false
      end
      draw_next_row(remaining)
      continued = true
    end
    finish_section_line
    @cursor -= 8
  end

  def frame(title, x, top, width, height, header_height)
    @pdf.stroke_color(INK)
    @pdf.line_width(1.35)
    @pdf.stroke_rounded_rectangle([x, top], width, height, CARD_RADIUS)
    @pdf.stroke_color("D4D4D4")
    @pdf.line_width(0.6)
    @pdf.stroke_horizontal_line(x + PADDING, x + width - PADDING, at: top - header_height)
    @pdf.fill_color(INK)
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
      inner_width = @section_width - 2 * PADDING
      header = @pdf.height_of(title, width: inner_width, size: TITLE_SIZE, style: :bold, leading: 2) + 16
      available = @cursor - BOTTOM - header - 2 * PADDING
      options = {at: [@section_left + PADDING, @cursor - header - PADDING], width: inner_width,
                 height: available, leading: 2, document: @pdf}
      box = Prawn::Text::Formatted::Box.new(remaining.map(&:dup), options)
      leftover = box.render(dry_run: true)
      raise "An oversized resource field could not be laid out" if box.height.zero? || leftover == remaining
      record_category_page(entry)
      height = header + 2 * PADDING + box.height
      frame(title, @section_left, @cursor, @section_width, height, header)
      @pdf.formatted_text_box(remaining.map(&:dup), options.except(:document))
      @cursor -= height + GAP
      remaining = leftover
      if remaining.any?
        new_page
        draw_heading("#{category_name} continued", colour: @section_colour)
      end
      part += 1
    end
  end
end
