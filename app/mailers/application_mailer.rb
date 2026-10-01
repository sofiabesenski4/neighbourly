class ApplicationMailer < ActionMailer::Base
  default from: Rails.configuration.x.no_reply_email
  layout "mailer"
end
