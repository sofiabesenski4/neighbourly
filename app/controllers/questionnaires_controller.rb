# The guided questionnaire for someone seeking services for themselves.
#
# Architecture: GET shows the question. POST reads the answers through Questionnaire, which
# runs the search. The results page is being built separately, so for now the POST returns
# a plain list of service names, only to check that the search works.
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
    @questionnaire = Questionnaire.new(answers: submitted_answers)
    return render_question(NOT_UNDERSTOOD, status: :unprocessable_content) unless @questionnaire.valid?

    # Temporary, until the results page exists. ResourceCard supplies the names because it
    # has a fallback for a service without one.
    render plain: @questionnaire.services.map { |service| ResourceCard.new(service).title }.join("\n")
  end

  private

  NOT_UNDERSTOOD = "We couldn't read your answer. Choose from the options below, or continue without choosing any."
  RATE_LIMITED = "We've had a lot of requests from this connection. Your answers are still here. Please try again later."
  private_constant :NOT_UNDERSTOOD, :RATE_LIMITED

  # Shows the question again with what was chosen still ticked. Redirecting, as the app's
  # shared rate limit handler does, would lose the answers.
  def render_question(message, status:)
    @questionnaire ||= Questionnaire.new(answers: submitted_answers)
    @message = message
    render :show, status: status
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
