class PagesController < ApplicationController
  def home
    @landing_question = if user_signed_in?
      LandingQuestion.restore(session[:landing_question_token])
    else
      LandingQuestion.new
    end
  end
end
