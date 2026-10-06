namespace :reports do
  desc "Send daily digest emails for pending moderation reports to all admins"
  task daily_digest: :environment do
    ReportDigestJob.perform_later
    puts "Enqueued ReportDigestJob for daily digest delivery"
  end
end
