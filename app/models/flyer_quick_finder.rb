require "rqrcode_core"

# Draws the index into reserved pages once the resource pages have been laid out.
class FlyerQuickFinder
  Group = Data.define(:parent_name, :colour, :categories) do
    def heading
      parent_name unless categories.first == parent_name
    end

    def height
      child_count = categories.size - (heading ? 0 : 1)
      PARENT_ROW_HEIGHT + child_count * CHILD_ROW_HEIGHT
    end
  end
  PALETTE = %w[4477AA EE6677 228833 CCBB44 66CCEE AA3377].freeze
  DEFAULT_URL = "https://github.com/sofiabesenski4/neighbourly".freeze
  INK = "1A1A1A"
  LINK_COLOUR = "263B64"
  GUTTER = 23
  PARENT_ROW_HEIGHT = 28
  CHILD_ROW_HEIGHT = 23
  GROUP_GAP = 5
  # Leave room for the website and notes boxes on a full index page.
  MAX_COLUMN_HEIGHT = 337
  PARENT_SIZE = 9.75
  CHILD_SIZE = 9
  CATEGORY_INSET = 7
  CHILD_INDENT = 10
  SECTION_GAP = 36
  WEBSITE_HEIGHT = 75
  FOOTER_RULE_Y = 4
  NOTES_FOOTER_GAP = 14

  def initialize(pdf, categories:)
    @pdf = pdf
    @width = pdf.bounds.width
    @url = ENV["NEIGHBOURLY_PUBLIC_URL"].presence || DEFAULT_URL
    groups = category_groups(categories)
    @category_colours = groups.each_with_object({}) do |group, colours|
      group.categories.each { |name| colours[name] = group.colour }
    end
    @columns = build_columns(groups)
  end

  def colour_for(category_name)
    @category_colours.fetch(category_name)
  end

  def page_count
    (@columns.size + 1) / 2
  end

  def draw(printed_pages)
    printed_pages.values.filter_map(&:first).uniq.each do |number|
      page = @pdf.state.pages.fetch(number - 1)
      @pdf.add_dest(destination(number), @pdf.dest_fit(page))
    end

    @columns.each_slice(2).with_index do |columns, page_index|
      @pdf.go_to_page(2 + page_index)
      draw_page(columns, printed_pages, page_index)
    end
  end

  private

  def category_groups(categories)
    tree = CategoryTree.new
    remaining = categories.to_set
    colours = PALETTE.cycle
    groups = tree.children_of.filter_map do |root|
      colour = colours.next
      names = branch_names(tree, root).select { |name| remaining.delete?(name) }
      next if names.empty?

      Group.new(root.name, colour, names)
    end
    groups + remaining.sort.map { |name| Group.new(name, colours.next, [name]) }
  end

  def branch_names(tree, category)
    [category.name] + tree.children_of(category).flat_map { |child| branch_names(tree, child) }
  end

  def build_columns(groups)
    midpoint = (groups.size + 1) / 2
    balanced = [groups.take(midpoint), groups.drop(midpoint)].reject(&:empty?)
    return balanced if balanced.any? && balanced.all? { |column| column.sum(&:height) + (column.size - 1) * GROUP_GAP <= MAX_COLUMN_HEIGHT }

    columns = [[]]
    used = 0
    max_children = (MAX_COLUMN_HEIGHT - PARENT_ROW_HEIGHT) / CHILD_ROW_HEIGHT
    groups.each do |group|
      chunks = (group.height > MAX_COLUMN_HEIGHT) ? group.categories.each_slice(max_children) : [group.categories]
      chunks.each do |names|
        chunk = group.with(categories: names)
        used += GROUP_GAP unless columns.last.empty?
        if used + chunk.height > MAX_COLUMN_HEIGHT
          columns << []
          used = 0
        end
        columns.last << chunk
        used += chunk.height
      end
    end
    columns
  end

  def draw_page(columns, printed_pages, page_index)
    FlyerPdf.draw_page_header(@pdf)
    @pdf.move_cursor_to(@pdf.bounds.top - FlyerPdf::PAGE_HEADER_HEIGHT)
    @pdf.text(page_index.zero? ? "Quick finder" : "Quick finder continued", size: 23.25, style: :bold)
    @pdf.move_down(6)
    @pdf.text("Find a service, then turn to the page shown.", size: 10.5)
    @pdf.move_down(17)

    width = (@width - GUTTER) / 2
    top = @pdf.cursor
    bottoms = columns.each_with_index.map do |groups, index|
      draw_column(groups, printed_pages, index * (width + GUTTER), top, width)
    end
    website_top = (bottoms.min || top) - SECTION_GAP
    draw_website(website_top)
    draw_notes(website_top - WEBSITE_HEIGHT - SECTION_GAP)

    @pdf.stroke_color(FlyerPdf::GOLD)
    @pdf.line_width(1.5)
    @pdf.stroke_horizontal_line(0, @width, at: FOOTER_RULE_Y)
    @pdf.text_box("Neighbourly Resource Guide", at: [0, -4], width: @width, height: 12, size: 8.25)
    @pdf.text_box("Page #{@pdf.page_number} of #{@pdf.page_count}", at: [0, -4], width: @width, height: 12, size: 8.25, align: :right)
  end

  def draw_website(top)
    outline(0, top, @width, WEBSITE_HEIGHT, 9, "2D3953")
    @pdf.formatted_text_box([
      {text: "Made with Neighbourly. ", styles: [:bold]},
      {text: "Hours and services may change, so call ahead if possible."}
    ], at: [9, top - 14], width: @width - 92, height: 26, size: 9.75)
    @pdf.formatted_text_box([{text: @url, styles: [:bold], link: @url, color: LINK_COLOUR}],
      at: [9, top - 43], width: @width - 92, height: 26, size: 9.75, overflow: :shrink_to_fit)
    draw_qr(@width - 68, top - 7)
  end

  def draw_qr(x, top)
    modules = @qr_modules ||= RQRCodeCore::QRCode.new(@url, level: :m).modules
    unit = 61.5 / (modules.size + 8)
    @pdf.fill_color(INK)
    modules.each_with_index do |row, y|
      row.each_with_index do |dark, column|
        @pdf.fill_rectangle([x + (column + 4) * unit, top - (y + 4) * unit], unit, unit) if dark
      end
    end
  end

  def draw_column(groups, printed_pages, x, top, width)
    groups.each_with_index do |group, index|
      top -= GROUP_GAP unless index.zero?
      @pdf.fill_color(group.colour)
      @pdf.fill_rectangle([x, top - 4], 3, 15)
      @pdf.fill_color(INK)
      if group.heading
        draw_category_name(group.heading, x, top, width)
        top -= PARENT_ROW_HEIGHT
      end
      group.categories.each do |name|
        top = draw_row(name, printed_pages.fetch(name), x, top, width, child: name != group.parent_name)
      end
    end
    top
  end

  def draw_row(name, pages, x, top, width, child:)
    reference = page_reference(pages)
    reference = "Page #{pages.first}" if @pdf.width_of(reference, size: 8.25, style: :bold) > width / 2
    reference_width = @pdf.width_of(reference, size: 8.25, style: :bold) + 2
    reference_left = x + width - reference_width

    draw_category_name(name, x, top, reference_left - x - 10, child: child)
    @pdf.formatted_text_box([{text: reference, styles: [:bold], anchor: destination(pages.first), color: LINK_COLOUR}],
      at: [reference_left, top - 8], width: reference_width, height: 12, size: 8.25, align: :right)
    @pdf.stroke_color("DFE4DC")
    @pdf.line_width(0.5)
    bottom = top - (child ? CHILD_ROW_HEIGHT : PARENT_ROW_HEIGHT)
    @pdf.stroke_horizontal_line(x, x + width, at: bottom + 1)
    bottom
  end

  def draw_category_name(name, x, top, width, child: false)
    inset = CATEGORY_INSET + (child ? CHILD_INDENT : 0)
    height = child ? CHILD_ROW_HEIGHT : PARENT_ROW_HEIGHT
    @pdf.text_box(name, at: [x + inset, top - 7], width: width - inset,
      height: height - 8, size: child ? CHILD_SIZE : PARENT_SIZE, style: :bold, overflow: :shrink_to_fit, min_font_size: 7)
  end

  def page_reference(pages)
    return "Page #{pages.first}" if pages.size == 1

    ranges = pages.chunk_while { |left, right| right == left + 1 }.map do |range|
      (range.size == 1) ? range.first.to_s : "#{range.first}–#{range.last}"
    end
    "Pages #{ranges.join(", ")}"
  end

  def draw_notes(top)
    height = top - FOOTER_RULE_Y - NOTES_FOOTER_GAP
    outline(0, top, @width, height, 9, INK)
    @pdf.text_box("My notes", at: [9, top - 7], width: @width - 18, height: 14, size: 9.75, style: :bold)
    @pdf.stroke_color("C5C9C4")
    @pdf.line_width(0.5)
    22.step(height - 12, 17.25) { |offset| @pdf.stroke_horizontal_line(9, @width - 9, at: top - offset) }
  end

  def outline(x, top, width, height, radius, colour, weight = 1.125)
    @pdf.stroke_color(colour)
    @pdf.line_width(weight)
    @pdf.stroke_rounded_rectangle([x, top], width, height, radius)
  end

  def destination(page)
    "service-page-#{page}"
  end
end
