require "rails_helper"

RSpec.describe "Models", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }

  describe "GET /models" do
    context "when not signed in" do
      it "redirects to sign in" do
        get models_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "as a regular user" do
      before { sign_in regular_user }

      it "denies access" do
        get models_path

        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(response.body).to include("You are not authorized to perform this action")
      end
    end

    context "as an admin" do
      before { sign_in admin }
      before do
        chat_models = double(all: [])
        allow(RubyLLM).to receive(:models).and_return(double(chat_models: chat_models, refresh!: nil))
      end

      it "allows access" do
        get models_path

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "GET /models/:id" do
    let(:model_record) { Model.create!(model_id: "test-model", name: "Test Model", provider: "test") }

    context "when not signed in" do
      it "redirects to sign in" do
        get model_path(model_record)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "as a regular user" do
      before { sign_in regular_user }

      it "denies access" do
        get model_path(model_record)

        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(response.body).to include("You are not authorized to perform this action")
      end
    end

    context "as an admin" do
      before { sign_in admin }

      it "allows access" do
        get model_path(model_record)

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "POST /models/refresh" do
    before { allow(Model).to receive(:refresh!) }

    context "when not signed in" do
      it "redirects to sign in" do
        post refresh_models_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "as a regular user" do
      before { sign_in regular_user }

      it "denies access" do
        post refresh_models_path

        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(response.body).to include("You are not authorized to perform this action")
      end
    end

    context "as an admin" do
      before { sign_in admin }

      it "allows refreshing models" do
        allow(Model).to receive(:refresh!)

        post refresh_models_path

        expect(response).to redirect_to(models_path)
        expect(Model).to have_received(:refresh!)
      end
    end
  end
end
