require "rails_helper"

RSpec.describe "Workspace conversation deletion", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "delete@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  before do
    sign_in user
    chat
  end

  it "returns to a new chat when the open conversation is deleted" do
    delete chat_path(chat), params: {from: "workspace", current_chat_id: chat.id}, as: :turbo_stream

    expect(response).to redirect_to(new_chat_path)
    expect(Chat.exists?(chat.id)).to be(false)
  end

  it "removes sidebar rows without replacing the open conversation or its composer" do
    other_chat = user.chats.create!

    delete chat_path(other_chat), params: {from: "workspace", current_chat_id: chat.id}, as: :turbo_stream

    expect(response).to have_http_status(:ok)
    stream = Nokogiri::HTML(response.body).at_css("turbo-stream")
    expect(stream["action"]).to eq("remove")
    expect(stream["targets"]).to eq("[data-chat-row='#{other_chat.id}']")
    expect(response.body).not_to include('action="replace"')
    expect(Chat.exists?(chat.id)).to be(true)
  end

  it "removes sidebar rows while composing a new chat" do
    delete chat_path(chat), params: {from: "workspace"}, as: :turbo_stream

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('action="remove"')
  end

  it "does not allow deletion of another user's conversation" do
    other_user = User.create!(email: "private@example.com", password: "password123")
    private_chat = other_user.chats.create!

    expect {
      delete chat_path(private_chat), params: {from: "workspace", current_chat_id: chat.id}, as: :turbo_stream
    }.not_to change(Chat, :count)
  end

  it "does not redirect an HTML request to an unauthorized conversation" do
    other_user = User.create!(email: "private@example.com", password: "password123")
    private_chat = other_user.chats.create!

    delete chat_path(chat), params: {from: "workspace", current_chat_id: private_chat.id}

    expect(response).to redirect_to(new_chat_path)
  end
end
