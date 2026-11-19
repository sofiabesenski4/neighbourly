class ServicesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_service, only: [:show, :edit, :update, :destroy]
  after_action :verify_authorized

  def index
    authorize Service
    @services = policy_scope(Service).alphabetical.includes(:organization, :categories)
  end

  def show
    authorize @service
  end

  def new
    authorize Service
    # Opened from an organization's page, the new service starts linked to it.
    @service = Service.new(organization_id: params[:organization_id])
  end

  def create
    authorize Service
    # An admin is the source of a service added here, like a resource added
    # through the resource form.
    @service = Source.form_entry_source.services.build(service_params)
    if @service.save
      redirect_to @service, notice: "Service '#{@service.name}' was created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @service
  end

  def update
    authorize @service
    if @service.update(service_params)
      redirect_to @service, notice: "Service '#{@service.name}' was updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @service
    @service.destroy!
    redirect_to services_path, notice: "Service '#{@service.name}' was deleted.", status: :see_other
  end

  private

  def set_service
    @service = Service.find(params[:id])
  end

  def service_params
    params.require(:service).permit(
      :name, :organization_id, :description, :hours, :phone, :email, :website,
      :address_line, :city, :province, :postal_code, :country, :closed, category_ids: []
    )
  end
end
