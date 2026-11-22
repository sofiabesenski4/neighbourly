# Assigns colours in the category tree's order for the printout filters, preview, and PDF.
class FlyerCategoryPalette
  COLOURS = %w[335EA8 B14558 156247 896109 177B8C 782F7C].freeze
  Group = Data.define(:parent_name, :colour, :categories)

  attr_reader :groups

  def initialize(categories, tree: CategoryTree.new)
    remaining = categories.to_set
    colours = COLOURS.cycle
    @groups = tree.children_of.filter_map do |root|
      colour = colours.next
      names = branch_names(tree, root).select { |name| remaining.delete?(name) }
      next if names.empty?

      Group.new(root.name, colour, names)
    end
    @groups += remaining.sort.map { |name| Group.new(name, colours.next, [name]) }
    @colours = @groups.each_with_object({}) do |group, by_name|
      group.categories.each { |name| by_name[name] = group.colour }
    end
  end

  def colour_for(category_name)
    @colours.fetch(category_name)
  end

  private

  def branch_names(tree, category)
    [category.name] + tree.children_of(category).flat_map { |child| branch_names(tree, child) }
  end
end
