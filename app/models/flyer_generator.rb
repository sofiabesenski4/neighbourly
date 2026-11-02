# Builds the printable PDF for a set of flyer categories.
#
# Returns PDF bytes, or nil when the selected categories have no resources.
# The same grouped query is also available to the category preview endpoint.
class FlyerGenerator
  def self.call(categories:, printed_at: Time.current)
    sections = ResourceCategorySearch.call(categories: categories)
    return if sections.all? { |section| section.resources.empty? }

    FlyerPdf.new(sections: sections, printed_at: printed_at).render
  end
end
