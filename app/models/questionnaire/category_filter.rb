# Finds services in any of the categories behind the chosen options.
#
# Architecture: the config names categories, and this turns the names into the IDs that
# CategorySearch takes. The names are looked up on every request because categories can be
# renamed or removed while the app runs.
class Questionnaire
  class CategoryFilter < Filter
    # Options with at least one category that exists. Offering one with none would be worse
    # than leaving it out: with no category IDs, the search finds every service.
    #
    # Logs the missing names so a renamed category is noticed. It always checks every
    # option, so the log line says nothing about what anyone chose.
    def self.available(options)
      names = options.flat_map(&:categories)
      existing = Category.where(name: names).distinct.pluck(:name)
      missing = names - existing
      Rails.logger.warn("[Questionnaire] missing categories: #{missing.join(", ")}") if missing.any?

      options.select { |option| option.categories.intersect?(existing) }
    end

    def self.search_keys
      [:categories]
    end

    def search_options
      {categories: category_ids}
    end

    private

    # Strings, because CategorySearch validates them as submitted checkbox values.
    def category_ids
      Category.where(name: options.flat_map(&:categories)).pluck(:id).map(&:to_s)
    end
  end
end
