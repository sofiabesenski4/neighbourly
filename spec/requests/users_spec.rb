require "rails_helper"

RSpec.describe "Users", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin_user) { User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", password_confirmation: "password123") }
  let(:target_user) { User.create!(email: "target@example.com", password: "password123", password_confirmation: "password123") }

  describe "PATCH /users/:id" do
    context "as an admin" do
      before { sign_in admin_user }

      it "allows updating the email" do
        patch user_path(target_user), params: {user: {email: "new@example.com"}}

        expect(target_user.reload.email).to eq("new@example.com")
      end

      it "allows granting admin privileges" do
        patch user_path(target_user), params: {user: {admin: true}}

        expect(target_user.reload.admin?).to be true
      end

      it "allows revoking admin privileges" do
        another_admin = User.create!(email: "admin2@example.com", password: "password123", password_confirmation: "password123", admin: true)

        patch user_path(another_admin), params: {user: {admin: false}}

        expect(another_admin.reload.admin?).to be false
      end
    end

    context "as a regular user bypassing authorization" do
      before do
        sign_in regular_user
        allow_any_instance_of(UserPolicy).to receive(:update?).and_return(true)
      end

      it "cannot escalate own privileges to admin" do
        patch user_path(regular_user), params: {user: {email: regular_user.email, admin: true}}

        expect(regular_user.reload.admin?).to be false
      end

      it "cannot grant admin privileges to another user" do
        patch user_path(target_user), params: {user: {email: target_user.email, admin: true}}

        expect(target_user.reload.admin?).to be false
      end
    end

    context "when not signed in" do
      it "rejects the request" do
        patch user_path(target_user), params: {user: {admin: true}}

        expect(target_user.reload.admin?).to be false
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end
end
