require "rails_helper"

RSpec.describe "Pages", type: :request do
  include Devise::Test::IntegrationHelpers

  describe "GET /" do
    context "when signed out" do
      it "shows the sign up and sign in links" do
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(new_user_registration_path)
        expect(response.body).to include(new_user_session_path)
        expect(response.body).not_to include("What do you need, neighbour?")
      end
    end

    context "when signed in" do
      let(:user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }

      before { sign_in user }

      it "shows only the new chat button" do
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("What do you need, neighbour?")
        expect(response.body).to include(%(href="#{new_chat_path}"))
        expect(response.body).not_to include("Get started")
      end
    end
  end
end
