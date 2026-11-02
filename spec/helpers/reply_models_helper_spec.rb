require "rails_helper"

RSpec.describe ReplyModelsHelper, type: :helper do
  let(:user) { User.create!(email: "reply-models@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:message) { chat.messages.create!(role: "assistant", content: "An answer") }
  let(:model) { RubyLLM::Model.new(id: "recorded-model", name: "Recorded Model", provider: "anthropic") }

  before do
    chat
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([model]))
  end

  def record_usage(provider: "anthropic", model: "recorded-model", status: "succeeded", operation: "chat")
    message.ruby_llm_usages.create!(chat: chat, provider: provider, model: model, status: status, operation: operation)
  end

  it "uses the recorded provider and model rather than the conversation's current model" do
    record_usage

    expect(helper.reply_model_label(message)).to eq("Anthropic - Recorded Model")
    expect(chat.model_id).not_to eq("recorded-model")
  end

  it "does not infer a model for a reply without provenance" do
    expect(helper.reply_model_label(message)).to be_nil
  end

  it "uses the latest successful chat attempt and ignores other operations or unsuccessful attempts" do
    record_usage
    record_usage(model: "later-model")
    record_usage(model: "failed-model", status: "failed")
    record_usage(model: "cancelled-model", status: "cancelled")
    record_usage(model: "pending-model", status: "pending")
    record_usage(model: "image-model", operation: "image")

    expect(helper.reply_model_label(message)).to eq("anthropic: later-model")
  end

  it "does not claim a successful response model for a cancelled or failed attempt" do
    record_usage(status: "cancelled")
    record_usage(status: "failed")

    expect(helper.reply_model_label(message)).to be_nil
  end

  it "qualifies registry names by provider" do
    same_id = RubyLLM::Model.new(id: "recorded-model", name: "Other Provider Model", provider: "openai")
    allow(RubyLLM).to receive(:models).and_return(RubyLLM::Models.new([same_id, model]))
    record_usage

    expect(helper.reply_model_label(message)).to eq("Anthropic - Recorded Model")
  end

  it "preserves the recorded model ID when metadata is no longer in the registry" do
    record_usage(model: "retired-model")

    expect(helper.reply_model_label(message)).to eq("anthropic: retired-model")
  end

  it "supports preloaded usage without querying individual replies" do
    record_usage
    loaded_message = Message.includes(:ruby_llm_usages).find(message.id)
    expect(loaded_message.ruby_llm_usages).not_to receive(:where)

    expect(helper.reply_model_label(loaded_message)).to eq("Anthropic - Recorded Model")
  end

  it "finds the latest successful attempt even if preloaded records are not ordered" do
    record_usage
    record_usage(model: "later-model")
    loaded_message = Message.includes(:ruby_llm_usages).find(message.id)
    loaded_message.association(:ruby_llm_usages).target.reverse!

    expect(helper.reply_model_label(loaded_message)).to eq("anthropic: later-model")
  end
end
