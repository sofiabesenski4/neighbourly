# The guided questionnaire for someone seeking services for themselves.
#
# Architecture: GET shows the first question, with no answers. Each POST submits the question
# shown, the button pressed and every answer so far. Questionnaire works out where that
# leads: another question, or past the last one to the search. The results page is being
# built separately, so for now the search returns a plain list of service names, only to
# check that it works.
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

  def show
    @questionnaire = Questionnaire.new
  end

  def create
    @questionnaire = submitted_questionnaire
    @questionnaire.move(submitted(:move))
    return render_question(NOT_UNDERSTOOD, status: :unprocessable_content) unless @questionnaire.valid?
    return render :show unless @questionnaire.finished?

    # Temporary, until the results page exists. ResourceCard supplies the names because it
    # has a fallback for a service without one.
    render plain: @questionnaire.services.map { |service| ResourceCard.new(service).title }.join("\n")
  end

  private

  NOT_UNDERSTOOD = "We couldn't read your answer. Choose from the options below, or continue without choosing any."
  RATE_LIMITED = "We've had a lot of requests from this connection. Your answers are still here. Please try again later."
  private_constant :NOT_UNDERSTOOD, :RATE_LIMITED

  # Shows a question with a message, and what was chosen still ticked. Over the rate limit
  # that's the question the person was on. Redirecting, as the app's shared rate limit
  # handler does, would lose the answers.
  def render_question(message, status:)
    @questionnaire ||= submitted_questionnaire
    @message = message
    render :show, status: status
  end

  def submitted_questionnaire
    Questionnaire.new(answers: submitted_answers, step: submitted(:step))
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
