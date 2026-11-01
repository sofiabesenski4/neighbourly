require "rails_helper"

RSpec.describe ChatsHelper, type: :helper do
  let(:user) { User.create!(email: "titles@example.com", password: "password123") }
  let(:chat) { user.chats.create! }

  describe "#chat_title" do
    it "uses the first user question and normalizes whitespace" do
      chat.messages.create!(role: "system", content: "Internal instructions")
      chat.messages.create!(role: "assistant", content: "Hello")
      chat.messages.create!(role: "user", content: "Find food\n  in Victoria")
      chat.messages.create!(role: "user", content: "A later question")

      expect(helper.chat_title(chat)).to eq("Find food in Victoria")
    end

    it "provides a title before the first question has been saved" do
      expect(helper.chat_title(Chat.new)).to eq("New conversation")
      expect(helper.chat_title(chat)).to eq("New conversation")
    end

    it "keeps long questions from dominating navigation" do
      chat.messages.create!(role: "user", content: "Help me find food support. " * 20)

      title = helper.chat_title(chat)
      expect(title.length).to eq(80)
      expect(title).to start_with("Help me find food support.")
      expect(title).to end_with("...")
    end
  end
end
