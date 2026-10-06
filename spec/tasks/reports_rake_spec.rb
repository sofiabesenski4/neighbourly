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
      expect(ReportDigestJob).to receive(:perform_later)
      Rake::Task["reports:daily_digest"].invoke
    end
  end
end
