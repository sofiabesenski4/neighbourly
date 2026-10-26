require "rails_helper"

RSpec.describe "config/recurring.yml" do
  let(:config) { ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")) }

  %w[staging production].each do |env|
    it "schedules the report digest in #{env}" do
      task = SolidQueue::RecurringTask.from_configuration(:report_digest, **config.fetch(env).fetch("report_digest").symbolize_keys)

      expect(task).to be_valid
      expect(task.class_name.constantize).to eq(ReportDigestJob)
    end
  end

  it "sends the report digest at 8am Vancouver time" do
    task = SolidQueue::RecurringTask.from_configuration(:report_digest, **config.fetch("production").fetch("report_digest").symbolize_keys)
    next_run = travel_to(Time.utc(2026, 7, 1, 12)) { task.next_time }

    expect(next_run.in_time_zone("America/Vancouver").strftime("%H:%M")).to eq("08:00")
  end
end
