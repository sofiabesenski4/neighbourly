class PagesController < ApplicationController
  def home
    @landing_question = LandingQuestion.restore(session[:landing_question_token])
  end
end
