require "rails_helper"

RSpec.describe "Administration navigation", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-navigation@example.com", password: "password123", admin: true) }
  let(:user) { User.create!(email: "member-navigation@example.com", password: "password123") }
  let(:model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }

  before do
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
  end

  def navigation
    Nokogiri::HTML(response.body).at_css("nav[aria-label='Main navigation']")
  end

  %w[users sources reports models].each do |section|
    it "shares the support header and selects the #{section} section" do
      sign_in admin
      destination = public_send("#{section}_path")

      get destination

      expect(response).to have_http_status(:ok)
      expect(navigation.at_css("a[href='#{root_path}']").text.squish).to eq("neighbourly")
      expect(navigation.at_css("a[href='#{new_chat_path}']").text.squish).to eq("Chat")
      printout = navigation.at_css("a[href='#{new_flyer_path}']")
      expect(printout.text.squish).to eq("Printout")
      expect(printout["data-turbo"]).to eq("false")
      administration = navigation.at_css("[aria-label='Administration']")
      expect(administration.css("a").map { |link| link["href"] }).to eq([users_path, sources_path, reports_path, models_path])
      expect(navigation.css("a[aria-current='page']").map { |link| link["href"] }).to eq([destination])
      expect(navigation.at_css("form[action='#{destroy_user_session_path}']")).to be_present
    end
  end

  it "keeps the source section selected while editing resources" do
    sign_in admin

    [new_source_path, new_document_path].each do |destination|
      get destination

      expect(response).to have_http_status(:ok)
      expect(navigation.at_css("a[aria-current='page']")["href"]).to eq(sources_path)
    end
  end

  it "does not show administration links to a regular account" do
    sign_in user
    get root_path

    expect(navigation.at_css("[aria-label='Administration']")).to be_nil
    [users_path, sources_path, reports_path, models_path].each do |destination|
      expect(navigation.at_css("a[href='#{destination}']")).to be_nil
    end
  end

  it "does not show administration links to a guest" do
    get root_path

    expect(navigation.at_css("[aria-label='Administration']")).to be_nil
    expect(navigation.at_css("a[href='#{new_user_session_path}']")).to be_present
  end
end
