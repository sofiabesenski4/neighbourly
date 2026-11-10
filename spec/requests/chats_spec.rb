require "rails_helper"

RSpec.describe "Chats", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", password_confirmation: "password123", admin: true) }
  let(:owner) { User.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123") }
  let(:other_user) { User.create!(email: "other@example.com", password: "password123", password_confirmation: "password123") }
  let(:chat) { owner.chats.create! }

  describe "GET /chats" do
    it "redirects a signed-in visitor to the workspace" do
      sign_in owner

      get chats_path

      expect(response).to redirect_to(new_chat_path)
    end

    it "redirects a guest to the public workspace" do
      get chats_path

      expect(response).to redirect_to(new_chat_path)
    end
  end

  describe "GET /chats/:id" do
    context "as the owner" do
      before { sign_in owner }

      it "allows access" do
        get chat_path(chat)

        expect(response).to have_http_status(:ok)
      end

      it "uses the first user question as the conversation title" do
        chat.messages.create!(role: "system", content: "Internal instructions")
        chat.messages.create!(role: "user", content: "Find food\n in Victoria")
        chat.messages.create!(role: "user", content: "A later question")

        get chat_path(chat)

        html = Nokogiri::HTML(response.body)
        expect(html.at_css("h1").text).to eq("Find food in Victoria")
        expect(html.at_css("#chat_sidebar a[aria-current='page']").text.squish).to eq("Find food in Victoria")
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

  describe "GET /chats/new" do
    it "limits recent conversations to the signed-in user's chats" do
      sign_in owner
      chat.messages.create!(role: "user", content: "My conversation")
      private_chat = other_user.chats.create!
      private_chat.messages.create!(role: "user", content: "Another user's private question")

      get new_chat_path

      html = Nokogiri::HTML(response.body)
      expect(html.at_css("#chat_sidebar").text).to include("My conversation")
      expect(response.body).not_to include("Another user's private question", chat_path(private_chat))
      expect(html.at_css("h1").text).to eq("New conversation")
    end

    it "keeps the workspace sidebar personal for admins" do
      sign_in admin
      own_chat = admin.chats.create!
      chat

      get new_chat_path

      sidebar = Nokogiri::HTML(response.body).at_css("#chat_sidebar")
      expect(sidebar.css("a").map { |link| link["href"] }).to include(chat_path(own_chat))
      expect(sidebar.css("a").map { |link| link["href"] }).not_to include(chat_path(chat))
    end

    it "lists older conversations after the newest 30" do
      sign_in owner
      oldest_chat = owner.chats.create!(created_at: 2.days.ago)
      recent_chats = Array.new(30) { owner.chats.create! }

      get new_chat_path

      links = Nokogiri::HTML(response.body).css("#chat_sidebar nav a").map { |link| link["href"] }
      expect(links).to eq(recent_chats.reverse.map { |recent_chat| chat_path(recent_chat) } + [chat_path(oldest_chat)])
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
        expect(response).to redirect_to(new_chat_path)
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
