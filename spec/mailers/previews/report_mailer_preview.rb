# Preview at http://localhost:3000/rails/mailers/report_mailer/daily_digest
class ReportMailerPreview < ActionMailer::Preview
  def daily_digest
    ReportMailer.with(
      admin: User.find_by(admin: true) || User.new(email: "admin@example.com"),
      report_ids: Report.pending.limit(10).pluck(:id)
    ).daily_digest
  end
end
