# Loads the category hierarchy once for the filter controls or resource search.
class CategoryTree
  def initialize
    @categories = Category.order(:name, :id).to_a
    @children_by_parent = @categories.group_by(&:parent_id)
  end

  def children_of(parent = nil)
    @children_by_parent.fetch(parent&.id, [])
  end

  def expand(selection)
    return @categories if selection.empty?

    ids = selection.map(&:to_i).to_set
    pending = @categories.select { |category| ids.include?(category.id) }
    until pending.empty?
      children_of(pending.pop).each do |child|
        pending << child if ids.add?(child.id)
      end
    end
    @categories.select { |category| ids.include?(category.id) }
  end
end
