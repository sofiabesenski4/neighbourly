# Builds the printable PDF from the same filters as the live guide.
#
# Returns PDF bytes, or nil when the selected categories have no resources.
# The same grouped query is also available to the category preview endpoint.
# An optional FlyerOrigin adds distances from that place to the printed cards.
class FlyerGenerator
  def self.call(origin: nil, printed_at: Time.current, detail_level: "detailed", **filters)
    sections = CategorySearch.call(**filters, origin: origin)
    return if sections.all? { |section| section.resources.empty? }

    FlyerPdf.new(sections: sections, origin: origin, printed_at: printed_at, detail_level: detail_level).render
  end
end
