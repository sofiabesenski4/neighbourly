require "rails_helper"

RSpec.describe "Messages", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:owner) { User.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123") }
  let(:other_user) { User.create!(email: "other@example.com", password: "password123", password_confirmation: "password123") }
  let(:chat) { owner.chats.create! }

  describe "POST /chats/:chat_id/messages" do
    context "when not signed in" do
      it "rejects the request" do
        post chat_messages_path(chat), params: {message: {content: "hello"}}

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "as the chat owner" do
      before { sign_in owner }

      it "allows creating a message" do
        post chat_messages_path(chat), params: {message: {content: "hello"}}

        expect(response).not_to have_http_status(:unauthorized)
        expect(response).not_to redirect_to(new_user_session_path)
      end
    end

    context "as another user" do
      before { sign_in other_user }

      it "denies access" do
        post chat_messages_path(chat), params: {message: {content: "hello"}}

        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(response.body).to include("You are not authorized to perform this action")
      end
    end
  end
end
