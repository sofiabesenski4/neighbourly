class PagesController < ApplicationController
  def home
    @landing_question = if user_signed_in?
      LandingQuestion.restore(session[:landing_question_token])
    else
      LandingQuestion.new
    end
  end

  # A page saying this isn't ready yet, until there's a flow for it.
  def find_help_for_someone_else
  end
end
