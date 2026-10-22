# Shared input to the category preview and its PDF. This query never calls an
# embedding service or a chat model.
class ResourceCategorySearch
  Section = Data.define(:category, :resources)

  def self.call(categories:, scope: Document.all)
    selection = Flyer.new(categories: categories)
    raise ArgumentError, selection.errors.full_messages.to_sentence unless selection.valid?

    selected = ResourceCategory.with_keys(selection.categories)
    matching = selected.map { |category| Document.in_category(category.key) }.reduce(&:or)

    # Match the prototype's searchable resources and keep accepted removals
    # hidden even if a later edit has regenerated an embedding. Formal
    # published/pending/archived states are still the responsibility of #65.
    resources = scope.with_embeddings
      .where.not(id: Report.where(status: "valid").select(:document_id))
      .where("metadata ->> 'closed' IS DISTINCT FROM 'true'")
      .where(id: matching.select(:id))
      .select(:id, :source_id, :title, :content, :metadata)
      .includes(:source)
      .order(Arel.sql("LOWER(documents.title) ASC"), :id)
      .to_a

    selected.map do |category|
      Section.new(category: category, resources: resources.select { |resource|
        Array(resource.metadata["resource_categories"]).include?(category.key)
      })
    end
  end
end
