class ModelsController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize :model, :index?
    @models = available_chat_models
  end

  def show
    authorize :model, :show?
    @model = RubyLLM.models.find(params[:id], provider: params[:provider].presence)
  end

  def refresh
    authorize :model, :refresh?
    RubyLLM.models.refresh
    redirect_to models_path, notice: "Models refreshed successfully"
  end
end
