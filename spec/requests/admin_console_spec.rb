require "rails_helper"

RSpec.describe "Admin console", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "console-admin@example.com", password: "password123", admin: true) }
  let(:user) { User.create!(email: "console-member@example.com", password: "password123") }
  let(:model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }

  before do
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
  end

  it "requires a signed-in account" do
    get admin_path

    expect(response).to redirect_to(new_user_session_path)
  end

  it "denies access to a regular account" do
    sign_in user
    get admin_path

    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response.body).to include("You are not authorized to perform this action.")
    expect(Nokogiri::HTML(response.body).at_css("[aria-label='Administration sections']")).to be_nil
  end

  it "shows current account, source, pending-report, and model counts to an administrator" do
    user
    source = Source.create!(name: "Community directory", source_type: "csv")
    document = source.documents.create!(title: "Community kitchen", content: "Meals every day.")
    Source.form_entry_source.documents.create!(title: "Community hub", content: "Drop-in support.")
    Report.create!(document: document, user: user, reason: "out of date")
    Report.create!(document: document, user: user, reason: "other", status: "dismissed")
    sign_in admin

    get admin_path

    expect(response).to have_http_status(:ok)
    sections = Nokogiri::HTML(response.body).at_css("[aria-label='Administration sections']")
    {users_path => "2", sources_path => "1", reports_path => "1", models_path => "1"}.each do |path, count|
      expect(sections.at_css("a[href='#{path}'] dd").text.squish).to eq(count)
    end
    expect(sections.at_css("a[href='#{sources_path}']").text.squish).to include("2 resources")
    expect(response.body).to include(%(href="#{new_source_path}"), %(href="#{new_document_path}"))
  end
end
