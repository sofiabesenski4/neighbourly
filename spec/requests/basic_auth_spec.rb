require "rails_helper"

RSpec.describe "Basic authentication", type: :request do
  let(:username) { "site_user" }
  let(:password) { "site_pass" }
  let(:credentials) { ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }

  around do |example|
    original_enabled = ENV["BASIC_AUTH_ENABLED"]
    original_username = ENV["BASIC_AUTH_USERNAME"]
    original_password = ENV["BASIC_AUTH_PASSWORD"]
    ENV["BASIC_AUTH_USERNAME"] = username
    ENV["BASIC_AUTH_PASSWORD"] = password
    example.run
  ensure
    ENV["BASIC_AUTH_ENABLED"] = original_enabled
    ENV["BASIC_AUTH_USERNAME"] = original_username
    ENV["BASIC_AUTH_PASSWORD"] = original_password
  end

  context "when enabled" do
    before { ENV["BASIC_AUTH_ENABLED"] = "true" }

    it "rejects requests with no credentials" do
      get root_path

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects requests with wrong credentials" do
      wrong = ActionController::HttpAuthentication::Basic.encode_credentials("wrong", "creds")

      get root_path, headers: {"HTTP_AUTHORIZATION" => wrong}

      expect(response).to have_http_status(:unauthorized)
    end

    it "allows requests with correct credentials" do
      get root_path, headers: {"HTTP_AUTHORIZATION" => credentials}

      expect(response).not_to have_http_status(:unauthorized)
    end
  end

  context "when disabled" do
    before { ENV["BASIC_AUTH_ENABLED"] = "false" }

    it "does not challenge for credentials" do
      get root_path

      expect(response).not_to have_http_status(:unauthorized)
    end
  end

  context "when unset" do
    before { ENV["BASIC_AUTH_ENABLED"] = nil }

    it "challenges for credentials by default" do
      get root_path

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
