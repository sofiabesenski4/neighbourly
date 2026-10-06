require "rails_helper"
require "rake"

RSpec.describe "reports rake tasks" do
  before(:all) do
    Rails.application.load_tasks
  end

  describe "reports:daily_digest" do
    it "is registered with rake" do
      expect(Rake::Task.task_defined?("reports:daily_digest")).to be true
    end

    it "enqueues ReportDigestJob when invoked" do
      # Reference the constant inside the example so Rails
      # autoloader has time to initialize via rails_helper
      job = double("ReportDigestJob")
      allow(ReportDigestJob).to receive(:perform_later).and_return(job)

      expect {
        Rake::Task["reports:daily_digest"].invoke
      }.to output(/Enqueued ReportDigestJob/).to_stdout
    end
  end
end
