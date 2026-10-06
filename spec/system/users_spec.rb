require "rails_helper"

RSpec.describe "Users", type: :system do
  around do |example|
    original = ENV["BASIC_AUTH_ENABLED"]
    ENV["BASIC_AUTH_ENABLED"] = "false"
    driven_by(:rack_test)
    example.run
  ensure
    ENV["BASIC_AUTH_ENABLED"] = original
  end

  let(:admin_user) { User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }
  let(:another_user) { User.create!(email: "another@example.com", password: "password123", password_confirmation: "password123") }

  describe "navigation" do
    context "as an admin user" do
      before do
        login_as(admin_user, scope: :user)
      end

      it "shows Users link in navigation" do
        visit root_path

        expect(page).to have_link("Users", href: users_path)
      end
    end

    context "as a regular user" do
      before do
        login_as(regular_user, scope: :user)
      end

      it "does not show Users link in navigation" do
        visit root_path

        expect(page).not_to have_link("Users", href: users_path)
      end
    end
  end

  describe "viewing users" do
    context "as an admin user" do
      before do
        login_as(admin_user, scope: :user)
        regular_user
        another_user
      end

      it "allows viewing the users index" do
        visit users_path

        expect(page).to have_content("Users")
        expect(page).to have_content("Manage user accounts")
        expect(page).to have_content(admin_user.email)
        expect(page).to have_content(regular_user.email)
        expect(page).to have_content(another_user.email)
      end

      it "shows admin badge for admin users" do
        visit users_path

        within("tr", text: admin_user.email) do
          expect(page).to have_content("Admin")
        end
      end

      it "shows user badge for regular users" do
        visit users_path

        within("tr", text: regular_user.email) do
          expect(page).to have_content("User")
        end
      end

      it "allows viewing individual user details" do
        visit users_path

        click_link "View", match: :first

        expect(page).to have_content("User Details")
        expect(page).to have_content("Account Information")
      end
    end

    context "as a regular user" do
      before do
        login_as(regular_user, scope: :user)
      end

      it "prevents viewing the users index" do
        visit users_path

        expect(page).to have_content("You are not authorized to perform this action")
      end
    end
  end

  describe "modifying user accounts" do
    context "as an admin user" do
      before do
        login_as(admin_user, scope: :user)
        regular_user
      end

      it "allows editing a user's email" do
        visit users_path

        within("tr", text: regular_user.email) do
          click_link "Edit"
        end

        expect(page).to have_content("Edit User")

        fill_in "Email", with: "newemail@example.com"
        click_button "Update User"

        expect(page).to have_content("User was successfully updated")
        expect(page).to have_content("newemail@example.com")
        expect(User.find(regular_user.id).email).to eq("newemail@example.com")
      end

      it "allows promoting a user to admin" do
        visit edit_user_path(regular_user)

        check "Admin"
        click_button "Update User"

        expect(page).to have_content("User was successfully updated")

        visit users_path

        within("tr", text: regular_user.email) do
          expect(page).to have_content("Admin")
        end

        expect(User.find(regular_user.id).admin?).to be true
      end

      it "allows demoting an admin to regular user" do
        another_admin = User.create!(email: "admin2@example.com", password: "password123", password_confirmation: "password123", admin: true)

        visit edit_user_path(another_admin)

        uncheck "Admin"
        click_button "Update User"

        expect(page).to have_content("User was successfully updated")

        visit users_path

        within("tr", text: another_admin.email) do
          expect(page).to have_content("User")
        end

        expect(User.find(another_admin.id).admin?).to be false
      end
    end

    context "as a regular user" do
      before do
        login_as(regular_user, scope: :user)
      end

      it "prevents editing other users" do
        visit edit_user_path(another_user)

        expect(page).to have_content("You are not authorized to perform this action")
      end
    end
  end

  describe "deleting user accounts" do
    context "as an admin user" do
      before do
        login_as(admin_user, scope: :user)
        regular_user
      end

      it "allows deleting a user account" do
        visit user_path(regular_user)

        click_button "Delete User"

        expect(page).to have_content("User was successfully deleted")
        expect(User.exists?(regular_user.id)).to be false
      end

      it "prevents deleting their own account" do
        visit user_path(admin_user)

        expect(page).not_to have_button("Delete User")
      end

      it "shows error when trying to delete own account via direct request" do
        visit users_path

        expect {
          page.driver.delete user_path(admin_user)
        }.not_to change { User.count }
      end
    end

    context "as a regular user" do
      before do
        login_as(regular_user, scope: :user)
        another_user
      end

      it "prevents deleting other users" do
        expect {
          page.driver.delete user_path(another_user)
        }.not_to change { User.count }
      end
    end
  end

  describe "authorization enforcement" do
    context "as a regular user" do
      before do
        login_as(regular_user, scope: :user)
      end

      it "redirects with error when accessing users index" do
        visit users_path

        expect(current_path).not_to eq(users_path)
        expect(page).to have_content("You are not authorized to perform this action")
      end

      it "redirects with error when accessing user show page" do
        visit user_path(another_user)

        expect(current_path).not_to eq(user_path(another_user))
        expect(page).to have_content("You are not authorized to perform this action")
      end
    end
  end
end
