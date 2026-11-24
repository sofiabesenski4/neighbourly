# One question from config/questionnaire.yml, and how to read an answer to it.
#
# Architecture: Questionnaire holds a list of these. The views draw a question using its
# `type` as the name of a partial, so a new question of an existing type needs no new view.
class Questionnaire
  Question = Data.define(:key, :title, :hint, :type, :filter, :all_options) do
    # Builds a question from one entry of the config.
    def self.from_config(entry)
      type = entry.fetch("type")
      raise KeyError, "unknown question type: #{type}" unless self::TYPES.include?(type)

      new(
        key: entry.fetch("key"),
        title: entry.fetch("title"),
        hint: entry["hint"],
        type: type,
        filter: FILTERS.fetch(entry.fetch("filter")),
        all_options: ((type == "location") ? [] : entry.fetch("options")).map { |option| Option.from_config(option) }
      )
    end

    # The options people can choose. The filter leaves out any it couldn't search for.
    # Not memoized: a Data object is frozen.
    def options
      filter.available(all_options)
    end

    # Turns what was submitted into an Answer, or a LocationAnswer. Checkboxes and radio
    # buttons both submit a list of option keys, or nothing at all when none is chosen. A
    # radio question's list has one, so more than one can't have come from the form.
    #
    # Unknown keys are ignored as long as at least one is known. That covers an option that
    # was removed while someone had the page open. When nothing that was submitted is
    # known, the answer is invalid, because ignoring it all would mean searching for
    # everything.
    def read(submitted)
      return LocationAnswer.read(submitted) if type == "location"
      return Answer.new(options: [], valid: true) if submitted.nil?
      return Answer.new(options: [], valid: false) unless submitted.is_a?(Array) && submitted.all?(String)

      keys = submitted.compact_blank
      selected = keys.empty? ? [] : options.select { |option| keys.include?(option.key) }
      return Answer.new(options: [], valid: false) if type == "radio" && selected.many?

      Answer.new(options: selected, valid: keys.empty? || selected.any?)
    end
  end

  # How a question can be asked. Each has a partial: app/views/questionnaires/_<type>.html.erb
  Question::TYPES = %w[checkboxes radio location].freeze
end
