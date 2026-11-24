# A question about a service's details, for specs that prove one can be added with only a
# config entry and a filter. Nothing here is in the real questionnaire.
#
# AgeFilter is the example in the README. Keep the two the same.
#
# Include the module and call use_age_question, which adds it after the real questions. Pass
# a filter to use another one for it, and other settings to change its config entry.
module AgeQuestion
  class AgeFilter < Questionnaire::Filter
    BRACKETS = {"under_19" => 0..18, "19_up" => 19..}.freeze

    # Hides a service only when its ages are known and don't overlap the answer.
    def keep?(service)
      ages = ResourceAttributes.new(service).age_range
      ages.nil? || options.any? { |option| ages.overlap?(BRACKETS.fetch(option.key)) }
    end
  end

  ENTRY = {
    "key" => "age",
    "title" => "How old are you?",
    "type" => "radio",
    "filter" => "AgeFilter",
    "options" => [{"key" => "under_19", "label" => "Under 19"}, {"key" => "19_up", "label" => "19 or older"}]
  }.freeze

  def use_age_question(filter: AgeFilter, **settings)
    stub_const("Questionnaire::FILTERS", Questionnaire::FILTERS.merge("AgeFilter" => filter))
    # It may already be replaced by an earlier call.
    allow(Questionnaire).to receive(:questions_from).and_call_original
    config = YAML.safe_load_file(Questionnaire::CONFIG_PATH)
    config["questions"] << ENTRY.merge(settings.stringify_keys)
    questions = Tempfile.create(["questionnaire", ".yml"]) do |file|
      file.write(config.to_yaml)
      file.flush
      Questionnaire.questions_from(file.path)
    end
    allow(Questionnaire).to receive(:questions_from).and_return(questions)
  end
end
