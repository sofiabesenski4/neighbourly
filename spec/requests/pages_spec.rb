require "rails_helper"

RSpec.describe "Pages", type: :request do
  include Devise::Test::IntegrationHelpers

  describe "GET /" do
    shared_examples "a community-resource welcome" do
      it "offers the landing navigation with real destinations" do
        get root_path

        navigation = Nokogiri::HTML(response.body).css("nav[aria-label='Main navigation']")
        expect(navigation.length).to eq(1)
        navigation = navigation.first
        expect(navigation.at_css("a[href='#{root_path}']").text.squish).to eq("neighbourly")
        expect(navigation.at_css("a[href='#{new_chat_path}']").text.squish).to eq("Chat")
        expect(navigation.css("a[aria-current]")).to be_empty
        expect(navigation.css("a.bg-sage-100")).to be_empty
        printout = navigation.at_css("a[href='#{new_flyer_path}']")
        expect(printout.text.squish).to eq("Printout")
        expect(printout["data-turbo"]).to eq("false")
        expect(navigation.text).not_to include("Saved")
      end

      it "explains paper guides and links directly to the printout builder" do
        get root_path

        document = Nokogiri::HTML(response.body)
        section = document.at_css("section[aria-labelledby='printout-heading']")
        expect(section).not_to be_nil
        expect(section.at_css("h2#printout-heading").text.squish).to eq("Prefer a paper copy?")
        expect(section.text).to include("Make a paper guide with addresses, hours, and contact details.")
        link = section.at_css("a[href='#{new_flyer_path}']")
        expect(link.text.squish).to eq("Create printout")
        expect(link.at_css("svg[aria-hidden='true'][stroke='currentColor']")).to be_present
        expect(document.css("a[href='#{new_flyer_path}']").map { |item| item["data-turbo"] }.uniq).to eq(["false"])
        expect(document.at_css("main").text).not_to include("Make a printable flyer", "save your printout template")
      end

      it "explains the page purpose with one main heading" do
        get root_path

        document = Nokogiri::HTML(response.body)
        expect(document.css("main h1").map { |heading| heading.text.squish })
          .to eq(["What would help you today?"])

        hero = document.at_css("section[aria-labelledby='home-heading']")
        expect(hero).not_to be_nil
        expect(hero.at_css("h1#home-heading").text.squish).to eq("What would help you today?")
        expect(hero.text).to include("Victoria, BC")
        expect(hero.text).to include("Find food, shelter, health care, and everyday support nearby.")
      end

      it "describes community features without claiming verification" do
        get root_path

        expect(response.body).not_to include("verified community resources")

        document = Nokogiri::HTML(response.body)
        features = document.at_css("section[aria-label='How Neighbourly helps']")
        expect(features).not_to be_nil
        expect(features.css("article").map { |article| [article.at_css("h2").text.squish, article.at_css("p").text.squish] })
          .to eq([
            ["Ask in plain language", "Describe what you need and get relevant results from community resources."],
            ["Local organizations", "Information sourced from shelters, food banks, health centres, and other community services."],
            ["Community moderated", "Users can flag outdated or incorrect information to keep results accurate and trustworthy."]
          ])
      end
    end

    context "when signed out" do
      include_examples "a community-resource welcome"

      it "offers sign-in to start a question" do
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(new_user_session_path)
        expect(response.body).to include("Sign in to start chat")
        expect(response.body).not_to include("Ask anything")
      end
    end

    context "when signed in" do
      let(:user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }

      before { sign_in user }

      include_examples "a community-resource welcome"

      it "offers a direct chat start for signed-in visitors" do
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Start chat")
        expect(response.body).to include(%(href="#{new_chat_path}"))
        expect(response.body).not_to include("Get started")
      end
    end

    context "when signed in as an admin" do
      let(:admin) { User.create!(email: "landing-admin@example.com", password: "password123", admin: true) }

      it "keeps administration and account actions available" do
        sign_in admin
        get root_path

        navigation = Nokogiri::HTML(response.body).at_css("nav[aria-label='Main navigation']")
        expect(navigation.at_css("a[href='#{root_path}']").text.squish).to eq("neighbourly")
        expect(navigation.at_css("a[href='#{users_path}']").text.squish).to eq("Users")
        expect(navigation.at_css("a[href='#{sources_path}']").text.squish).to eq("Sources")
        expect(navigation.at_css("a[href='#{reports_path}']").text.squish).to eq("Moderation")
        sign_out_form = navigation.at_css("form[action='#{destroy_user_session_path}']")
        expect(sign_out_form.at_css("input[name='_method']")["value"]).to eq("delete")
        expect(sign_out_form.at_css("button").text.squish).to eq("Sign out")
      end
    end
  end

  describe "navigation outside the landing page" do
    it "shares the landing brand and tabs with the printout page" do
      get new_flyer_path

      expect(response).to have_http_status(:ok)
      navigation = Nokogiri::HTML(response.body).at_css("nav[aria-label='Main navigation']")
      expect(navigation.at_css("a[href='#{root_path}']").text.squish).to eq("neighbourly")
      expect(navigation.at_css("a[href='#{new_flyer_path}']").text.squish).to eq("Printout")
      expect(navigation.at_css("a[aria-current='page']").text.squish).to eq("Printout")
    end
  end
end
