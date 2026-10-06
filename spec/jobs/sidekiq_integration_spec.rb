require "rails_helper"

RSpec.describe "Sidekiq Configuration" do
  it "includes sidekiq in the Gemfile for staging and production" do
    gemfile = Rails.root.join("Gemfile").read
    expect(gemfile).to include("gem \"sidekiq\"")
  end

  it "configures sidekiq as the queue adapter in production" do
    prod_config = Rails.root.join("config/environments/production.rb").read
    expect(prod_config).to include("config.active_job.queue_adapter = :sidekiq")
  end

  it "configures sidekiq as the queue adapter in staging" do
    staging_config = Rails.root.join("config/environments/staging.rb").read
    expect(staging_config).to include("config.active_job.queue_adapter = :sidekiq")
  end

  it "adds sidekiq worker to the Procfile" do
    procfile = Rails.root.join("Procfile").read
    expect(procfile).to include("worker: bundle exec sidekiq")
  end
end
