# The guided questionnaire for someone seeking services for themselves: the questions
# being asked, and the answers given so far.
#
# Architecture: config/questionnaire.yml describes the questions. QuestionnairesController
# builds a Questionnaire from what was submitted, and the views draw its questions. Each
# answered question becomes one filter, the filters' search options are merged, and
# CategorySearch runs the search. That is the same search printouts use, so the two always
# agree about which services match.
#
# Answers across questions narrow the search. An unanswered question adds no filter, so
# answering nothing finds every visible service.
#
# Privacy: nothing here is saved. Answers may be sensitive, so they live only in the form
# and in this object while the request lasts. Never put them in a URL, a log line or an
# error report.
class Questionnaire
  CONFIG_PATH = Rails.root.join("config/questionnaire.yml")

  # The filters a question may use. The name in the config is looked up here instead of
  # being turned straight into a class, so the config can only ever reach these.
  FILTERS = {"CategoryFilter" => CategoryFilter}.freeze

  # The order when no filter asks for another. It also makes CategorySearch return one
  # flat list: its default sort groups by category and repeats a service in each.
  DEFAULT_SEARCH = {categories: [], sort: "asc"}.freeze

  # Reads the questions from a config file. An unknown type or filter raises KeyError. The
  # specs load the real file, so a mistake in it is caught before it's deployed.
  def self.questions_from(path = CONFIG_PATH)
    YAML.safe_load_file(path).fetch("questions").map { |entry| Question.from_config(entry) }
  end

  attr_reader :questions

  # `answers` is what was submitted, by question key. It can be anything a browser or a
  # script might send, so Question#read decides what it means. Keys that aren't questions
  # are ignored, because each question looks up only its own.
  def initialize(answers: {}, questions: self.class.questions_from)
    @questions = questions
    @submitted = answers.is_a?(Hash) ? answers : {}
    @malformed = !answers.is_a?(Hash)
  end

  # The question to show.
  def question
    questions.first
  end

  # The chosen options for a question. Empty when it was skipped.
  def chosen(question)
    answer_to(question).options
  end

  # False when something was submitted that can't be understood. Searching anyway would
  # treat it as no answer and show every service, which isn't what the person asked for.
  def valid?
    !@malformed && questions.all? { |question| answer_to(question).valid? }
  end

  # The matching services, each once.
  def services
    CategorySearch.call(**search_options).flat_map(&:resources)
  end

  private

  # Each answer is read once, since reading it looks up which options are available.
  def answer_to(question)
    @answers ||= {}
    @answers[question.key] ||= question.read(@submitted[question.key])
  end

  def search_options
    filters.map(&:search_options).reduce(DEFAULT_SEARCH, :merge)
  end

  def filters
    questions.filter_map do |question|
      options = chosen(question)
      question.filter.new(options) if options.any?
    end
  end
end
