# Shared input to the category preview and its PDF. This query never calls an
# embedding service or a chat model.
class CategorySearch
  Section = Data.define(:category, :resources, :label) do
    def initialize(category:, resources:, label: nil)
      super(category: category, resources: resources, label: label)
    end

    def name
      label || category&.name || "Other resources"
    end
  end

  def self.call(categories:, query: "", sort: Flyer::DEFAULT_SORT, scope: Document.all)
    selection = Flyer.new(categories: categories, query: query, sort: sort)
    raise ArgumentError, selection.errors.full_messages.to_sentence unless selection.valid?

    unfiltered = selection.categories.empty?
    selected = Category.order(:name, :id)
    selected = selected.where(id: selection.categories) unless unfiltered
    selected = selected.to_a

    # A saved resource is printable without a search embedding. Keep closed
    # resources and accepted removals hidden until a publication workflow
    # replaces this prototype visibility rule (issue #65).
    resources = scope
      .where.not(id: Report.where(status: "valid").select(:document_id))
      .where("metadata ->> 'closed' IS DISTINCT FROM 'true'")
      .select(:id, :source_id, :title, :content, :metadata)

    unless unfiltered
      matching = Document.in_categories(selection.categories)
      resources = resources.where(id: matching.select(:id))
    end

    resources = resources
      .includes(:source, :categories)
      .order(Arel.sql("LOWER(documents.title) ASC"), :id)
      .to_a

    if selection.query.present?
      term = selection.query.downcase
      resources.select! do |resource|
        card = ResourceCard.new(resource)
        [card.title, *resource.category_names, *card.fields.pluck(:value)].any? { |text| text.downcase.include?(term) }
      end
    end

    if selection.sort != Flyer::DEFAULT_SORT
      resources.sort_by! { |resource| [ResourceCard.new(resource).title.downcase, resource.id] }
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
