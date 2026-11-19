class OrganizationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_organization, only: [:show, :edit, :update, :destroy]
  after_action :verify_authorized

  def index
    authorize Organization
    @organizations = policy_scope(Organization).alphabetical
    @service_counts = Service.where(organization: @organizations).group(:organization_id).count
  end

  def show
    authorize @organization
    @services = @organization.services.alphabetical.includes(:categories, :address)
  end

  def new
    authorize Organization
    @organization = Organization.new
  end

  def create
    authorize Organization
    @organization = Organization.new(organization_params)
    if @organization.save
      redirect_to @organization, notice: "Organization '#{@organization.name}' was created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @organization
  end

  def update
    authorize @organization
    if @organization.update(organization_params)
      redirect_to @organization, notice: "Organization '#{@organization.name}' was updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @organization
    @organization.destroy!
    redirect_to organizations_path, notice: "Organization '#{@organization.name}' was deleted. Its services were kept.", status: :see_other
  end

  private

  def set_organization
    @organization = Organization.find(params[:id])
  end

  def organization_params
    params.require(:organization).permit(:name, :description, :website, :email, :phone, address_attributes: [:id, :street_address, :city, :province, :postal_code, :country])
  end
end
