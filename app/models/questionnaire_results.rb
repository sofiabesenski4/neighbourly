# Everything the results page needs about a finished questionnaire.
#
# Architecture: Questionnaire#results builds one once the person has moved past the last
# question, and QuestionnairesController hands it to the guided printout as @results.
# See docs/questionnaire-results.md for the contract.
#
# - `services`: matching Service records, in the order to show them, each once. Empty when
#   nothing matches.
# - `category_ids`: the category selection used by the search.
# - `origin`: the FlyerOrigin that distances are measured from, or nil when the location
#   question was skipped. It has no point when the place couldn't be looked up.
# - `answers`: an Answer for each answered question, in the order they're asked.
# - `missing_distances?`: whether a place was given but couldn't be looked up. The page
#   should say that the services aren't sorted by distance.
# - `hidden_fields`: [name, value] for every answer. Only _change_answer uses this.
#
# Privacy: this holds someone's answers. It's only for the response being rendered.
QuestionnaireResults = Data.define(:services, :origin, :answers, :missing_distances, :hidden_fields, :category_ids) do
  def missing_distances?
    missing_distances
  end

  def category_groups(tree:)
    matching_categories = tree.expand(category_ids)
    matching_ids = matching_categories.map(&:id).to_set
    groups = services.group_by do |service|
      category = service.categories.find { |candidate| matching_ids.include?(candidate.id) }
      (category || service.categories.first)&.name || "Other resources"
    end
    groups.slice(*matching_categories.map(&:name)).merge(groups)
  end
end

# One answered question, in words: its key, its title and the labels that were chosen. A
# location's label is the place that was typed, or "your location" for the device's.
QuestionnaireResults::Answer = Data.define(:key, :title, :labels)
