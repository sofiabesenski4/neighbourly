class ServicesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_service, only: [:show, :edit, :update, :destroy, :confirm]
  after_action :verify_authorized

  def index
    authorize Service
    @sort = Service::SORTS.key?(params[:sort]) ? params[:sort] : "name"
    @direction = (params[:direction] == "desc") ? "desc" : "asc"
    @services = policy_scope(Service).sorted_by(@sort, @direction).includes(:organization, :categories, :address)
  end

  def show
    authorize @service
  end

  def new
    authorize Service
    # Opened from an organization's page, the new service starts linked to
    # it. A member's always belongs to their organization.
    organization_id = current_user.admin? ? params[:organization_id] : current_user.organization_id
    @service = Service.new(organization_id: organization_id)
  end

  def create
    authorize Service
    # The person adding it is the source of a service added here, like a
    # resource added through the resource form.
    @service = Source.form_entry_source.services.build(service_params)
    @service.organization_id = current_user.organization_id unless current_user.admin?
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

  # Someone who can edit a service checked its details are still right.
  def confirm
    authorize @service, :update?
    how = params[:confirmation_method]
    if Service::CHECKING_METHODS.key?(how)
      @service.confirm!(by: current_user, method: how)
      redirect_to @service, notice: "Service '#{@service.name}' was confirmed #{Service::CONFIRMATION_METHODS[how]}."
    else
      redirect_to @service, alert: "Choose how you confirmed the details."
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

  # Only admins choose which organization offers a service. A member's
  # services stay with their organization.
  def service_params
    fields = [:name, :description, :hours, :phone, :email, :website, :closed,
      category_ids: [], address_attributes: [:id, :street_address, :city, :province, :postal_code, :country]]
    fields.unshift(:organization_id) if current_user.admin?
    params.require(:service).permit(*fields)
  end
end
