# The guided questionnaire for someone seeking services for themselves: the questions
# being asked, the answers given so far, and which question the person is on.
#
# Architecture: config/questionnaire.yml describes the questions. QuestionnairesController
# builds a Questionnaire from what was submitted, calls #move with the button pressed, and
# shows either the question it lands on or, once #finished?, the results. Each answered
# question becomes one filter, the filters' search options are merged, and CategorySearch
# runs the search. That is the same search printouts use, so the two always agree about
# which services match.
#
# Answers across questions narrow the search. An unanswered question adds no filter, so
# answering nothing finds every visible service. The order of answering makes no difference.
#
# Nothing is remembered between requests. Every screen submits all the answers so far, and
# the key of the question it shows. Keys are used instead of numbers because hiding a
# question would renumber the rest.
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
    questions = YAML.safe_load_file(path).fetch("questions").map { |entry| Question.from_config(entry) }
    reject_clashing_filters(questions)
    questions
  end

  # Filters' search options are merged, so if two questions set the same one, the later
  # answer would replace the earlier one when it should narrow it.
  def self.reject_clashing_filters(questions)
    clashes = questions.flat_map { |question| question.filter.search_keys }.tally.select { |_, count| count > 1 }.keys
    raise ArgumentError, "more than one question sets: #{clashes.join(", ")}" if clashes.any?
  end
  private_class_method :reject_clashing_filters

  attr_reader :questions, :question

  # `answers` is what was submitted, by question key. It can be anything a browser or a
  # script might send, so Question#read decides what it means. Keys that aren't questions
  # are ignored, because each question looks up only its own.
  #
  # `step` is the key of the question the person was on. Without one, it's the first.
  def initialize(answers: {}, step: nil, questions: self.class.questions_from)
    @questions = questions
    @submitted = answers.is_a?(Hash) ? answers : {}
    @malformed = !answers.is_a?(Hash)
    @question = step.nil? ? questions.first : questions.find { |question| question.key == step }
    @unknown_step = @question.nil?
    @question ||= questions.first
    @finished = false
  end

  # Moves on from the current question, according to the button pressed. Anything other
  # than "back" or "skip" counts as "next", which is what Enter submits.
  #
  # A step that isn't a question leaves the person on the first one, with their answers.
  # It may have been removed from the config while they had the page open.
  def move(direction)
    if @unknown_step
      ask_unreadable_again
    elsif direction == "back"
      go_back
    else
      discard(question) if direction == "skip"
      go_forward
    end
  end

  # True once the person has moved past the last question.
  def finished?
    @finished
  end

  # 1 for the first question.
  def position
    questions.index(question) + 1
  end

  def first?
    position == 1
  end

  # The chosen options for a question. Empty when it was skipped.
  def chosen(question)
    answer_to(question).options
  end

  # False when something was submitted that can't be understood. Searching anyway would
  # treat it as no answer and show every service, which isn't what the person asked for.
  def valid?
    !@malformed && unreadable.empty?
  end

  # The matching services, each once.
  def services
    CategorySearch.call(**search_options).flat_map(&:resources)
  end

  private

  # Going back isn't a reason to complain about an answer that can't be read. It's dropped,
  # and the person comes to that question again on the way forward.
  def go_back
    @malformed = false
    unreadable.each { |question| discard(question) }
    @question = questions[questions.index(question) - 1] unless first?
  end

  def go_forward
    return ask_unreadable_again unless valid?

    following = questions[questions.index(question) + 1]
    following ? @question = following : @finished = true
  end

  # Shows the first question whose answer couldn't be read, which may not be the one the
  # person was on. Stays put when there is none to blame.
  def ask_unreadable_again
    @question = unreadable.first || question
  end

  def unreadable
    questions.reject { |question| answer_to(question).valid? }
  end

  def discard(question)
    @submitted = @submitted.except(question.key)
    @answers&.delete(question.key)
  end

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
