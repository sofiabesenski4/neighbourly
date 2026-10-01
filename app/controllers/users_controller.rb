class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user, only: [:show, :edit, :update, :destroy]
  after_action :verify_authorized

  def index
    authorize User
    @users = policy_scope(User).order(created_at: :desc)
  end

  def show
    authorize @user
  end

  def edit
    authorize @user
  end

  def update
    authorize @user

    attrs = user_params
    attrs[:admin] = params[:user][:admin] if current_user.admin? && params[:user].key?(:admin)

    if @user.update(attrs)
      redirect_to @user, notice: "User was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @user

    if @user == current_user
      redirect_to users_path, alert: "You cannot delete your own account."
      return
    end

    @user.destroy!
    redirect_to users_path, notice: "User was successfully deleted.", status: :see_other
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def user_params
    params.require(:user).permit(:email)
  end
end
