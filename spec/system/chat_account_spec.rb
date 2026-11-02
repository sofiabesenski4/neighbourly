require "rails_helper"

RSpec.describe "Chat account navigation", type: :system do
  before { driven_by(:selenium_chrome_headless) }

  it "shows the signed-in email beside Sign Out in the workspace" do
    user = User.create!(email: "account@example.com", password: "password123")
    login_as(user, scope: :user)
    page.current_window.resize_to(1280, 900)

    visit new_chat_path

    within("nav[aria-label='Main navigation']") do
      expect(page).to have_text(user.email)
      expect(page).to have_button("Sign Out")
    end
  end
end
