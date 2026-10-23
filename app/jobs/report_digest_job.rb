class ReportDigestJob < ApplicationJob
  # Admins only hear about reports they have not been told about yet, and get
  # no email at all on days with nothing new. Reports stay undigested while
  # there are no admins so the first admin still hears about them.
  def perform
    report_ids = Report.pending.undigested.ids
    admins = User.where(admin: true)
    return if report_ids.empty? || admins.none?

    Report.transaction do
      admins.find_each do |admin|
        ReportMailer.with(admin: admin, report_ids: report_ids).daily_digest.deliver_later
      end
      Report.where(id: report_ids).update_all(digested_at: Time.current)
    end
  end
end
