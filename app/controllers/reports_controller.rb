class ReportsController < ApplicationController
  before_action :authenticate_user!, except: [:create]
  after_action :verify_authorized

  # Reporting is deliberately open to anonymous users, which makes it the
  # easiest way to flood the moderation queue. Limit tightly on the document
  # being reported, since nobody needs to report the same listing repeatedly,
  # and keep the per-IP ceiling loose so a busy shelter or library connection
  # does not run out of reports for everyone behind it.
  rate_limit to: 3, within: 1.hour,
    by: -> { "#{request.remote_ip}:#{params.dig(:report, :document_id)}" },
    with: -> { rate_limit_exceeded("You've already reported this listing. Thank you — our moderators will review it.") },
    only: :create, name: "per-document"
  rate_limit to: 30, within: 1.hour,
    by: -> { request.remote_ip },
    with: -> { rate_limit_exceeded("We've received a lot of reports from this connection. Please try again later.") },
    only: :create, name: "per-ip"

  def index
    authorize Report
    @reports = policy_scope(Report).most_recent.includes(document: :source, user: [])
  end

  def create
    @report = Report.new(report_params)
    @report.user = current_user if user_signed_in?
    authorize @report

    if @report.save
      redirect_back fallback_location: root_path, notice: "Thank you. Your report has been submitted."
    else
      redirect_back fallback_location: root_path, alert: "Could not submit report. Please try again."
    end
  end

  def dismiss
    @report = Report.find(params[:id])
    authorize @report, :update?
    @report.update!(status: "dismissed")
    redirect_to reports_path, notice: "Report dismissed."
  end

  def validate
    @report = Report.find(params[:id])
    authorize @report, :update?

    document = @report.document

    Report.transaction do
      document.reports.pending.update_all(status: "valid")
      document.update_column(:embedding, nil)
    end

    redirect_to reports_path, notice: "Removal accepted. '#{document.title}' has been removed from search results."
  end

  private

  def report_params
    params.require(:report).permit(:document_id, :reason, :details)
  end
end
