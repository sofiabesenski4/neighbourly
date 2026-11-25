# The guided questionnaire for someone seeking services for themselves.
#
# Architecture: GET shows the first question, with no answers. Each POST submits the question
# shown, the button pressed and every answer so far. Questionnaire works out where that
# leads: another question, or past the last one to the guided printout preview. See
# docs/questionnaire-results.md.
#
# Privacy: answers may come to include gender, Indigenous identity, disability and mental
# health, and are often entered on shared computers. So they arrive only in the body of a
# POST, never in a URL, and aren't put in the session, cookies, cache or database. They're
# all nested under `questionnaire`, which the parameter filter hides from the logs.
class QuestionnairesController < ApplicationController
  # First, so that it also covers the rate limit response below.
  before_action :no_store

  # Open to anonymous users, like printouts. The limit is per connection, and a library or
  # shelter may share one, so it's the same as the printout preview's.
  rate_limit to: 300, within: 1.hour, name: "answers",
    by: -> { request.remote_ip },
    with: -> { render_question(RATE_LIMITED, status: :too_many_requests) },
    only: :create

  # Each lookup calls the address service for an anonymous visitor, so this also stops the
  # site being used as a free way into it. Only requests that need a lookup count. Over the
  # limit, people carry on without distances: this renders nothing, so the action still runs.
  rate_limit to: 60, within: 1.hour, name: "lookup",
    by: -> { request.remote_ip },
    with: -> { @lookups_used_up = true },
    only: :create, if: -> { submitted_questionnaire.lookup_needed?(submitted(:move)) }

  def show
    @questionnaire = Questionnaire.new
  end

  def create
    @questionnaire = submitted_questionnaire
    @questionnaire.move(submitted(:move), lookup: !@lookups_used_up)
    return render_question(PROBLEMS.fetch(@questionnaire.problem), status: :unprocessable_content) unless @questionnaire.valid?
    return render :show unless @questionnaire.finished?

    @results = @questionnaire.results
    @flyer = Flyer.new(sort: Flyer::SELECTION_SORT, detail_level: "summary")
    render :results
  end

  private

  # What to say when a question has to be asked again, by its answer's problem.
  PROBLEMS = {
    unreadable: "We couldn't read your answer. Please try again, or press Skip.",
    not_found: "We couldn't find that place. Check the spelling, try a street address or intersection nearby, or press Skip.",
    device: "We couldn't read your device's location. Please try again, type a nearby place, or press Skip.",
    too_long: "That's too long for us to look up. Please type a shorter address, or press Skip."
  }.freeze
  RATE_LIMITED = "We've had a lot of requests from this connection. Your answers are still here. Please try again later."
  private_constant :PROBLEMS, :RATE_LIMITED

  # Shows a question with a message, and what was chosen still ticked. Over the rate limit
  # that's the question the person was on. Redirecting, as the app's shared rate limit
  # handler does, would lose the answers.
  def render_question(message, status:)
    @questionnaire = submitted_questionnaire
    @message = message
    render :show, status: status
  end

  # Memoized, because a rate limit above may need it before the action does.
  def submitted_questionnaire
    @submitted_questionnaire ||= Questionnaire.new(answers: submitted_answers, step: submitted(:step))
  end

  # A submitted value other than the answers, or nil.
  def submitted(name)
    input = params[:questionnaire]
    input[name] if input.is_a?(ActionController::Parameters)
  end

  # The submitted answers as a plain hash. Anything else is passed on unchanged, for
  # Questionnaire to reject. Reading this without `permit` is safe: Questionnaire only looks
  # up the questions it knows and checks each value's type, and nothing is mass assigned.
  def submitted_answers
    input = params[:questionnaire]
    return {} if input.nil?

    answers = input.is_a?(ActionController::Parameters) ? input[:answers] : input
    return {} if answers.nil?

    answers.is_a?(ActionController::Parameters) ? answers.to_unsafe_h : answers
  end
end
