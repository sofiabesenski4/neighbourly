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

  # Each of `filters` responds to keep?(service) and rank(service), as Questionnaire::Filter
  # does. They choose services by details that aren't in columns, so they run here in Ruby
  # instead of in the query. Printouts pass none, which changes nothing.
  def self.call(categories:, organizations: [], query: "", sort: Flyer::DEFAULT_SORT, origin: nil, service_ids: nil, filters: [])
    selection = Flyer.new(categories: categories, organizations: organizations, query: query, sort: sort, service_ids: service_ids)
    raise ArgumentError, selection.errors.full_messages.to_sentence unless selection.valid?

    unfiltered = selection.categories.empty?
    selected = CategoryTree.new.expand(selection.categories)

    # Printouts list services. Closed services and accepted removals stay
    # hidden until a publication workflow replaces this prototype visibility
    # rule (issue #65).
    resources = Service.visible
    resources = resources.where(id: selection.service_ids) if selection.service_ids
    resources = resources.in_categories(selected.map(&:id)) unless unfiltered
    # Someone printing for one organization, or a few, sees only what they offer.
    resources = resources.where(organization_id: selection.organizations) if selection.organizations.any?
    resources = resources.includes(:source, :categories, :address).alphabetical.to_a

    if selection.query.present?
      term = selection.query.downcase
      resources.select! do |resource|
        card = ResourceCard.new(resource)
        [card.title, *resource.category_names, *card.fields.pluck(:value)].any? { |text| text.downcase.include?(term) }
      end
    end

    resources.select! { |resource| filters.all? { |filter| filter.keep?(resource) } }

    if selection.sort == Flyer::SELECTION_SORT
      # The questionnaire already ranked these cards. Keep their submitted order.
      by_id = resources.index_by { |resource| resource.id.to_s }
      ordered = selection.service_ids.filter_map { |id| by_id[id] }
      return [Section.new(category: nil, resources: ordered, label: "Resources")]
    end

    by_distance = selection.sort == Flyer::DISTANCE_SORT
    if selection.sort != Flyer::DEFAULT_SORT && (!by_distance || origin&.located?)
      resources.sort_by! do |resource|
        card = ResourceCard.new(resource, origin: origin)
        name_order = [card.title.downcase, resource.id]
        by_distance ? [card.distance_km || Float::INFINITY, *name_order] : name_order
      end
      resources.reverse! if selection.sort == "desc"
      resources = ranked(resources, filters)
      return [Section.new(category: nil, resources: resources, label: "Resources")]
    end

    resources = ranked(resources, filters)
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

  # Better matches first, otherwise in the order they were in. Ranks add up, so a service
  # that suits two answers comes before one that suits only one of them.
  def self.ranked(resources, filters)
    return resources if filters.empty?

    resources.sort_by.with_index { |resource, index| [filters.sum { |filter| filter.rank(resource) }, index] }
  end
  private_class_method :ranked
end
