require "rails_helper"

RSpec.describe ChatTitleJob, type: :job do
  let(:user) { User.create!(email: "titlejob@example.com", password: "password123") }
  let(:chat) { user.chats.create! }
  let(:llm) { instance_double(RubyLLM::Chat) }
  let(:response) { double("response", content: '"Food support in Victoria"') }

  before do
    allow(RubyLLM).to receive(:chat).and_return(llm)
    allow(llm).to receive(:with_instructions).and_return(llm)
    allow(llm).to receive(:with_max_output_tokens).and_return(llm)
    allow(llm).to receive(:ask).and_return(response)
    chat.messages.create!(role: "user", content: "I need free food in Victoria")
    chat.messages.create!(role: "assistant", content: "Here are some local options.")
  end

  it "saves a concise title using the conversation's selected model without adding messages" do
    expect {
      described_class.perform_now(chat.id)
    }.not_to change { chat.messages.count }

    expect(chat.reload.title).to eq("Food support in Victoria")
    expect(RubyLLM).to have_received(:chat).with(model: chat.model.model_id, provider: chat.model.provider)
  end

  it "broadcasts generated markup as plain text" do
    title = "<img src=x onerror=alert(1)>"
    allow(response).to receive(:content).and_return(title)

    expect {
      described_class.perform_now(chat.id)
    }.to have_broadcasted_to(chat.stream_name).with(
      satisfy("contains the title as text without HTML elements") do |payload|
        template = Nokogiri::HTML.fragment(payload).at_css("turbo-stream[action='update'] template")
        template&.text == title && template.element_children.empty?
      end
    )

    expect(chat.reload.title).to eq(title)
  end

  it "excludes system instructions and tool payloads and bounds the transcript" do
    chat.messages.create!(role: "system", content: "Private reference instructions")
    chat.messages.create!(role: "tool", content: "Internal tool payload")
    chat.messages.create!(role: "user", content: "x" * 2000)

    described_class.perform_now(chat.id)

    expect(llm).to have_received(:ask) do |transcript|
      expect(transcript).to include("user: I need free food in Victoria", "assistant: Here are some local options.")
      expect(transcript).not_to include("Private reference instructions", "Internal tool payload", "x" * 1001)
    end
  end

  it "does not regenerate a title on later replies" do
    chat.update!(title: "Existing title")

    described_class.perform_now(chat.id)

    expect(RubyLLM).not_to have_received(:chat)
    expect(chat.reload.title).to eq("Existing title")
  end

  it "does not generate a title before an assistant reply is available" do
    chat.messages.where(role: "assistant").update_all(content: "")

    described_class.perform_now(chat.id)

    expect(RubyLLM).not_to have_received(:chat)
    expect(chat.reload.title).to be_nil
  end

  it "leaves the fallback available when the title is empty" do
    allow(response).to receive(:content).and_return(" \n ")

    described_class.perform_now(chat.id)

    expect(chat.reload.title).to be_nil
  end

  it "limits unexpectedly long titles" do
    allow(response).to receive(:content).and_return("Food support " * 20)

    described_class.perform_now(chat.id)

    expect(chat.reload.title.length).to eq(60)
  end

  it "does not overwrite a title saved by another job during generation" do
    allow(llm).to receive(:ask) do
      chat.update!(title: "Already generated")
      response
    end

    described_class.perform_now(chat.id)

    expect(chat.reload.title).to eq("Already generated")
  end

  it "reports a title-service failure without failing the conversation" do
    error = Faraday::TimeoutError.new("Title service unavailable")
    allow(llm).to receive(:ask).and_raise(error)
    allow(Rails.error).to receive(:report)

    expect { described_class.perform_now(chat.id) }.not_to raise_error

    expect(chat.reload.title).to be_nil
    expect(Rails.error).to have_received(:report).with(error, context: {chat_id: chat.id, operation: "chat_title"})
  end

  it "discards work for a deleted conversation" do
    chat_id = chat.id
    chat.destroy!

    expect { described_class.perform_now(chat_id) }.not_to raise_error
    expect(RubyLLM).not_to have_received(:chat)
  end
end
