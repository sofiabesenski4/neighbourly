class ReportMailer < ApplicationMailer
  # One email per admin per day, listing the reports flagged since the last
  # digest. Several reports on the same listing collapse into one line so a
  # busy listing does not crowd out the rest.
  def daily_digest
    @admin = params[:admin]
    reports = Report.where(id: params[:report_ids]).includes(:document).most_recent
    @reports_by_document = reports.group_by(&:document)
    @new_count = reports.size
    @pending_count = Report.pending.count

    mail(to: @admin.email, subject: "#{@new_count} new #{"report".pluralize(@new_count)} to review")
  end
end
