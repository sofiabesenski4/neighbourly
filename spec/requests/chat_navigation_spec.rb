require "rails_helper"

RSpec.describe "Chat navigation", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "navigation@example.com", password: "password123") }

  it "links directly to the chat workspace from desktop and mobile navigation" do
    sign_in user
    get root_path

    links = Nokogiri::HTML(response.body).css("nav[aria-label='Main navigation'] a").select { |link| link.text == "Chat" }
    expect(links.length).to eq(2)
    expect(links.map { |link| link["href"] }).to all(eq(new_chat_path))
  end

  it "continues to require sign-in before entering the workspace" do
    get new_chat_path

    expect(response).to redirect_to(new_user_session_path)
  end
end
