class ModelsController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize :model, :index?
    @models = available_chat_models
  end

  def show
    @model = Model.find(params[:id])
    authorize @model
  end

  def refresh
    authorize :model, :refresh?
    Model.refresh!
    redirect_to models_path, notice: "Models refreshed successfully"
  end
end
