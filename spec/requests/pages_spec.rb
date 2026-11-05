require "rails_helper"

RSpec.describe "Pages", type: :request do
  include Devise::Test::IntegrationHelpers

  describe "GET /" do
    shared_examples "a community-resource welcome" do
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
    end

    context "when signed out" do
      include_examples "a community-resource welcome"

      it "shows the sign up and sign in links" do
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(new_user_registration_path)
        expect(response.body).to include(new_user_session_path)
        expect(response.body).not_to include("Ask anything")
      end

      it "links to the flyer generator" do
        get root_path

        expect(response.body).to include(%(href="#{new_flyer_path}"))
        flyer_links = Nokogiri::HTML(response.body).css(%(a[href="#{new_flyer_path}"]))
        expect(flyer_links).not_to be_empty
        expect(flyer_links.map { |link| link["data-turbo"] }.uniq).to eq(["false"])
      end
    end

    context "when signed in" do
      let(:user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }

      before { sign_in user }

      include_examples "a community-resource welcome"

      it "shows only the new chat button" do
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Ask anything")
        expect(response.body).to include(%(href="#{new_chat_path}"))
        expect(response.body).not_to include("Get started")
      end

      it "links to the flyer generator" do
        get root_path

        expect(response.body).to include(%(href="#{new_flyer_path}"))
        flyer_links = Nokogiri::HTML(response.body).css(%(a[href="#{new_flyer_path}"]))
        expect(flyer_links).not_to be_empty
        expect(flyer_links.map { |link| link["data-turbo"] }.uniq).to eq(["false"])
      end
    end
  end
end
