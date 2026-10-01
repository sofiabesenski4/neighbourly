require "rails_helper"

RSpec.describe "Content Security Policy", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "csp@example.com", password: "password123", password_confirmation: "password123") }

  before { sign_in user }

  it "sends an enforced CSP header" do
    get chats_path

    expect(response.headers["Content-Security-Policy"]).to be_present
  end

  it "does not merely report violations" do
    get chats_path

    expect(response.headers["Content-Security-Policy-Report-Only"]).to be_nil
  end

  it "restricts default-src to self" do
    get chats_path

    csp = response.headers["Content-Security-Policy"]
    expect(csp).to include("default-src 'self'")
  end

  it "restricts script-src to self" do
    get chats_path

    csp = response.headers["Content-Security-Policy"]
    expect(csp).to include("script-src 'self'")
  end

  it "restricts style-src to self" do
    get chats_path

    csp = response.headers["Content-Security-Policy"]
    expect(csp).to include("style-src 'self'")
  end

  it "disallows object-src" do
    get chats_path

    csp = response.headers["Content-Security-Policy"]
    expect(csp).to include("object-src 'none'")
  end

  it "allows WebSocket connections via connect-src" do
    get chats_path

    csp = response.headers["Content-Security-Policy"]
    expect(csp).to match(/connect-src[^;]*'self'/)
  end

  it "prevents clickjacking with frame-ancestors none" do
    get chats_path

    csp = response.headers["Content-Security-Policy"]
    expect(csp).to include("frame-ancestors 'none'")
  end
end
