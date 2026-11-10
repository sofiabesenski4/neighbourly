require "rails_helper"

RSpec.describe "Support page navigation", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "navigation@example.com", password: "password123") }
  let(:model) { RubyLLM::Model.new(id: "claude-haiku-4-5", name: "Claude Haiku", provider: "anthropic") }

  before do
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
    allow(RubyLLM.config).to receive(:anthropic_api_key).and_return("configured-for-test")
  end

  def navigation
    Nokogiri::HTML(response.body).at_css("nav[aria-label='Main navigation']")
  end

  it "links directly to the chat workspace from desktop and mobile navigation" do
    sign_in user
    get root_path

    links = navigation.css("a").select { |link| link.text.squish == "Chat" }
    expect(links.length).to eq(1)
    expect(links.map { |link| link["href"] }).to all(eq(new_chat_path))
  end

  it "uses the landing header in new and existing chat workspaces" do
    sign_in user
    get root_path
    landing_links = navigation.css("a").map { |link| [link["href"], link.text.squish, link.at_css("svg")&.to_html] }
    chat = user.chats.create!(model: model)

    [new_chat_path, chat_path(chat)].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(navigation.css("a").map { |link| [link["href"], link.text.squish, link.at_css("svg")&.to_html] }).to eq(landing_links)
      expect(navigation.at_css("a[aria-current='page']").text.squish).to eq("Chat")
    end
  end

  it "shares the landing header on sign-in without selecting a support tab" do
    get root_path
    landing_links = navigation.css("a").map { |link| [link["href"], link.text.squish, link.at_css("svg")&.to_html] }

    get new_user_session_path

    expect(response).to have_http_status(:ok)
    expect(navigation.css("a").map { |link| [link["href"], link.text.squish, link.at_css("svg")&.to_html] }).to eq(landing_links)
    expect(navigation.css("a[aria-current], a.bg-sage-100")).to be_empty
    expect(response.headers.fetch("Content-Security-Policy")).to include("frame-src 'none'")
  end

  it "gives guests the same brand and tabs with Printout active in the builder" do
    get new_flyer_path

    expect(navigation.at_css("a[href='#{root_path}']").text.squish).to eq("neighbourly")
    expect(navigation.css("a[aria-current='page']").length).to eq(1)
    expect(navigation.at_css("a[aria-current='page']").text.squish).to eq("Printout")
    expect(navigation.at_css("a[href='#{new_chat_path}']").text.squish).to eq("Chat")
    expect(navigation.at_css("a[href='#{new_flyer_path}']")["data-turbo"]).to eq("false")
    expect(navigation.at_css("a[href='#{new_user_session_path}']").text.squish).to eq("Sign in")
    expect(navigation.css("a[href='#{root_path}'] svg[fill='none'][stroke='currentColor']").length).to eq(1)
    expect(navigation.text).not_to include("Saved", "Flyers")
  end

  it "keeps account and administration actions on every support page" do
    user.update!(admin: true)
    sign_in user

    [root_path, new_chat_path, new_flyer_path].each do |path|
      get path

      expect(navigation.text).to include(user.email)
      expect(navigation.at_css("a[href='#{admin_path}']").text.squish).to eq("Admin console")
      expect(navigation.at_css("[aria-label='Administration']")).to be_nil
      form = navigation.at_css("form[action='#{destroy_user_session_path}']")
      expect(form.at_css("button").text.squish).to eq("Sign out")
      expect(form.at_css("button")["data-turbo"]).to eq("false")
      expect(form.at_css("input[name='_method']")["value"]).to eq("delete")
    end
  end

  it "keeps the app-wide policy against embedded content in the guest workspace" do
    get new_chat_path

    expect(response).to have_http_status(:ok)
    csp = response.headers.fetch("Content-Security-Policy")
    expect(csp).to include("frame-src 'none'", "object-src 'none'", "script-src 'self'")
  end
end
