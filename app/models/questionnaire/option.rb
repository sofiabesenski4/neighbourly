# One choice in a question, from config/questionnaire.yml.
#
# Architecture: a Question holds these. The views show the label and submit the key, and the
# question's filter uses the rest. `categories` is empty for options whose filter doesn't
# use categories.
class Questionnaire
  Option = Data.define(:key, :label, :categories) do
    def self.from_config(entry)
      new(key: entry.fetch("key"), label: entry.fetch("label"), categories: entry.fetch("categories", []))
    end
  end
end
