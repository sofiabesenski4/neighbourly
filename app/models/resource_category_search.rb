# Shared input to the category preview and its PDF. This query never calls an
# embedding service or a chat model.
class ResourceCategorySearch
  Section = Data.define(:category, :resources)

  def self.call(categories:, scope: Document.all)
    selection = Flyer.new(categories: categories)
    raise ArgumentError, selection.errors.full_messages.to_sentence unless selection.valid?

    unfiltered = selection.categories.empty?
    selected = unfiltered ? ResourceCategory.all : ResourceCategory.with_keys(selection.categories)

    # A saved resource is printable without a search embedding. Keep closed
    # resources and accepted removals hidden until a publication workflow
    # replaces this prototype visibility rule (issue #65).
    resources = scope
      .where.not(id: Report.where(status: "valid").select(:document_id))
      .where("metadata ->> 'closed' IS DISTINCT FROM 'true'")
      .select(:id, :source_id, :title, :content, :metadata)

    unless unfiltered
      matching = selected.map { |category| Document.in_category(category.key) }.reduce(&:or)
      resources = resources.where(id: matching.select(:id))
    end

    resources = resources
      .includes(:source)
      .order(Arel.sql("LOWER(documents.title) ASC"), :id)
      .to_a

    sections = selected.map do |category|
      Section.new(category: category, resources: resources.select { |resource|
        Array(resource.metadata["resource_categories"]).include?(category.key)
      })
    end

    if unfiltered
      known_keys = selected.map(&:key)
      other_resources = resources.reject { |resource|
        Array(resource.metadata["resource_categories"]).intersect?(known_keys)
      }
      if other_resources.any?
        category = ResourceCategory.new(key: "uncategorized", name: "Other resources", labels: [])
        sections << Section.new(category: category, resources: other_resources)
      end
    end

    sections
  end
end
