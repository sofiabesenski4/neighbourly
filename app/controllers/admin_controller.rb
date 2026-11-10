class AdminController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  def index
    authorize :admin, :index?

    @user_count = policy_scope(User).count
    source_scope = policy_scope(Source)
    @source_count = source_scope.where.not(source_type: "form").count
    @resource_count = Document.where(source_id: source_scope.select(:id)).count
    @pending_report_count = policy_scope(Report).pending.count
    @model_count = available_chat_models.size
  end
end
