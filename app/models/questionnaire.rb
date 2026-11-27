# The guided questionnaire for someone seeking services for themselves: the questions
# being asked, the answers given so far, and which question the person is on.
#
# Architecture: config/questionnaire.yml describes the questions. QuestionnairesController
# builds a Questionnaire from what was submitted, calls #move with the button pressed, and
# shows either the question it lands on or, once #finished?, the results. Each answered
# question becomes one filter, the filters' search options are merged, and CategorySearch
# runs the search, asking the filters about each service. That is the same search printouts
# use, so the two always agree about which services are in a category.
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
  FILTERS = {"CategoryFilter" => CategoryFilter, "LocationFilter" => LocationFilter}.freeze

  # The order when no filter asks for another. It also makes CategorySearch return one
  # flat list: its default sort groups by category and repeats a service in each.
  DEFAULT_SEARCH = {categories: [], sort: "asc"}.freeze

  # Reads the questions from a config file. An unknown type or filter raises KeyError. The
  # specs load the real file, so a mistake in it is caught before it's deployed.
  def self.questions_from(path = CONFIG_PATH)
    questions = YAML.safe_load_file(path).fetch("questions").map { |entry| Question.from_config(entry) }
    reject_clashing_filters(questions)
    raise ArgumentError, "every question has `requires`, so there could be none to ask" if questions.all?(&:requires)

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
  #
  # Questions that no service has data for are left out, which makes their answers unknown
  # keys. This looks at every visible service and never at the answers, so what someone
  # answers can't hide a later question.
  def initialize(answers: {}, step: nil, questions: self.class.questions_from)
    @questions = questions.select(&:askable?)
    @submitted = answers.is_a?(Hash) ? answers : {}
    @malformed = !answers.is_a?(Hash)
    @question = step.nil? ? @questions.first : @questions.find { |question| question.key == step }
    @unknown_step = @question.nil?
    @question ||= @questions.first
    @finished = false
  end

  # Moves on from the current question, according to the button pressed. "show" stays on it,
  # for changing an answer from the results. Anything other than "show", "back" or "skip"
  # counts as "next", which is what Enter submits.
  #
  # A step that isn't a question leaves the person on the first one, with their answers.
  # It may have been removed from the config, or hidden, while they had the page open.
  #
  # Going forward looks up a place typed on this question. `lookup: false` goes on without.
  def move(direction, lookup: true)
    if @unknown_step
      ask_unreadable_again
    elsif direction == "show"
      discard_unreadable
    elsif direction == "back"
      discard_unreadable
      go_back
    else
      discard(question) if direction == "skip"
      go_forward(lookup)
    end
  end

  # Whether #move would call the address service, so that the controller can limit how often
  # that happens. Only going forward does, and only for a place not looked up already.
  def lookup_needed?(direction)
    !@unknown_step && !%w[show back skip].include?(direction) && valid? && answer_to(question).lookup_needed?
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

  # What was answered to a question, as an Answer or LocationAnswer. Each is read once,
  # since reading one can look up which options are available.
  def answer_to(question)
    @answers ||= {}
    @answers[question.key] ||= question.read(@submitted[question.key])
  end

  # False when something was submitted that can't be understood. Searching anyway would
  # treat it as no answer and show every service, which isn't what the person asked for.
  def valid?
    !@malformed && unreadable.empty?
  end

  # Why the current question has to be asked again, for choosing what to tell the person.
  def problem
    answer_to(question).problem || :unreadable
  end

  # True when a place was given but couldn't be looked up, so the services aren't sorted by
  # distance as the person asked. They should be told.
  def missing_distances?
    answered.any? { |question| question.type == "location" && !answer_to(question).located? }
  end

  # What was found, for the results page. Call this once #finished?, because only then has
  # every answer been checked.
  def results
    QuestionnaireResults.new(
      services: services,
      origin: origin,
      answers: answered.map { |question|
        QuestionnaireResults::Answer.new(key: question.key, title: question.title, labels: answer_to(question).labels)
      },
      missing_distances: missing_distances?,
      hidden_fields: hidden_fields
    )
  end

  # The name and value of every hidden field needed to carry the answers to another screen,
  # since nothing is saved. A question's own page leaves itself out with `except`, because its
  # inputs are there to see.
  def hidden_fields(except: nil)
    questions.without(except).flat_map do |question|
      answer_to(question).fields.map { |suffix, value| ["questionnaire[answers][#{question.key}]#{suffix}", value] }
    end
  end

  # The matching services, each once.
  def services
    CategorySearch.call(**search_options, filters: filters).flat_map(&:resources)
  end

  private

  # Going back, or to change an answer, isn't a reason to complain about one that can't be
  # read. It's dropped, and the person comes to that question again on the way forward.
  def discard_unreadable
    @malformed = false
    unreadable.each { |question| discard(question) }
  end

  def go_back
    @question = questions[questions.index(question) - 1] unless first?
  end

  # The lookup comes after the check, so a place is only looked up when nothing else needs
  # fixing first. Not finding the place then makes the answer invalid.
  def go_forward(lookup)
    return ask_unreadable_again unless valid?

    @answers[question.key] = answer_to(question).resolve(lookup: lookup)
    return unless valid?

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

  # Where distances are measured from. Nil when no location was given.
  def origin
    located = answered.find { |question| question.type == "location" }
    answer_to(located).value if located
  end

  def search_options
    filters.map(&:search_options).reduce(DEFAULT_SEARCH, :merge)
  end

  def filters
    answered.map { |question| question.filter.new(answer_to(question).value) }
  end

  def answered
    questions.select { |question| answer_to(question).answered? }
  end
end
