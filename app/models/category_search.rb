# Shared input to the category preview and its PDF. This query never calls an
# embedding service or a chat model.
class CategorySearch
  Section = Data.define(:category, :resources, :label) do
    def initialize(category:, resources:, label: nil)
      super
    end

    def name
      label || category&.name || "Other resources"
    end
  end

  def self.call(categories:, query: "", sort: Flyer::DEFAULT_SORT, origin: nil, service_ids: nil)
    selection = Flyer.new(categories: categories, query: query, sort: sort, service_ids: service_ids)
    raise ArgumentError, selection.errors.full_messages.to_sentence unless selection.valid?

    unfiltered = selection.categories.empty?
    selected = Category.order(:name, :id)
    selected = selected.where(id: selection.categories) unless unfiltered
    selected = selected.to_a

    # Printouts list services. Closed services and accepted removals stay
    # hidden until a publication workflow replaces this prototype visibility
    # rule (issue #65).
    resources = Service.visible
    resources = resources.where(id: selection.service_ids) if selection.service_ids
    resources = resources.in_categories(selection.categories) unless unfiltered
    resources = resources.includes(:source, :categories, :address).alphabetical.to_a

    if selection.query.present?
      term = selection.query.downcase
      resources.select! do |resource|
        card = ResourceCard.new(resource)
        [card.title, *resource.category_names, *card.fields.pluck(:value)].any? { |text| text.downcase.include?(term) }
      end
    end

    by_distance = selection.sort == Flyer::DISTANCE_SORT
    if selection.sort != Flyer::DEFAULT_SORT && (!by_distance || origin&.located?)
      resources.sort_by! do |resource|
        card = ResourceCard.new(resource, origin: origin)
        name_order = [card.title.downcase, resource.id]
        by_distance ? [card.distance_km || Float::INFINITY, *name_order] : name_order
      end
      resources.reverse! if selection.sort == "desc"
      return [Section.new(category: nil, resources: resources, label: "Resources")]
    end

    sections = selected.map do |category|
      Section.new(category: category, resources: resources.select { |resource|
        resource.categories.include?(category)
      })
    end

    if unfiltered
      other_resources = resources.select { |resource| resource.categories.empty? }
      if other_resources.any?
        sections << Section.new(category: nil, resources: other_resources)
      end
    end

    sections
  end
end
