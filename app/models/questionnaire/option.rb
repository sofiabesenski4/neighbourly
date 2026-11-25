# One choice in a question, from config/questionnaire.yml.
#
# Architecture: a Question holds these. The views show the label and submit the key, and the
# question's filter uses the rest. `categories` is empty for options whose filter doesn't
# use categories.
class Questionnaire
  Option = Data.define(:key, :label, :categories, :parent_key) do
    def initialize(key:, label:, categories:, parent_key: nil)
      super
    end

    def self.from_config(entry)
      key = entry.fetch("key")
      children = entry.fetch("children", []).map { |child|
        new(key: child.fetch("key"), label: child.fetch("label"), categories: child.fetch("categories"), parent_key: key)
      }
      categories = (entry.fetch("categories", []) + children.flat_map(&:categories)).uniq
      [new(key: key, label: entry.fetch("label"), categories: categories), *children]
    end
  end
end
