require "rails_helper"

RSpec.describe "Chats", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123", admin: true) }
  let(:owner) { User.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123") }
  let(:other_user) { User.create!(email: "other@example.com", password: "password123", password_confirmation: "password123") }
  let(:chat) { owner.chats.create! }

  describe "GET /chats" do
    before do
      chat
      other_user.chats.create!
    end

    context "as the owner" do
      before { sign_in owner }

      it "only shows the user's own chats" do
        get chats_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(chat_path(chat))
        expect(response.body).not_to include(chat_path(other_user.chats.first))
      end
    end

    context "as an admin" do
      before { sign_in admin }

      it "shows all chats" do
        get chats_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(chat_path(chat))
        expect(response.body).to include(chat_path(other_user.chats.first))
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        get chats_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "GET /chats/:id" do
    context "as the owner" do
      before { sign_in owner }

      it "allows access" do
        get chat_path(chat)

        expect(response).to have_http_status(:ok)
      end
    end

    context "as an admin" do
      before { sign_in admin }

      it "allows access to any chat" do
        get chat_path(chat)

        expect(response).to have_http_status(:ok)
      end
    end

    context "as another user" do
      before { sign_in other_user }

      it "denies access" do
        get chat_path(chat)

        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(response.body).to include("You are not authorized to perform this action")
      end
    end
  end

  describe "DELETE /chats/:id" do
    context "as the owner" do
      before { sign_in owner }

      it "allows deletion" do
        delete_chat = owner.chats.create!

        expect {
          delete chat_path(delete_chat)
        }.to change(Chat, :count).by(-1)
      end
    end

    context "as an admin" do
      before { sign_in admin }

      it "allows deletion of any chat" do
        chat

        expect {
          delete chat_path(chat)
        }.to change(Chat, :count).by(-1)
      end
    end

    context "as another user" do
      before { sign_in other_user }

      it "denies deletion" do
        chat

        expect {
          delete chat_path(chat)
        }.not_to change(Chat, :count)
      end
    end
  end
end
