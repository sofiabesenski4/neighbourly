require "rails_helper"

RSpec.describe MessagesHelper, type: :helper do
  describe "#message_references" do
    before { allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0)) }

    let(:chat) { User.create!(email: "references@example.com", password: "password123").chats.create! }
    let(:message) { chat.messages.create!(role: "assistant", content: "Answer") }
    let(:source) { Source.create!(name: "Directory", source_type: "csv") }

    it "lists services first, then rows, and only lets a reference with a row be reported" do
      row = source.documents.create!(title: "Lunch row", content: "Lunch")
      imported = source.services.create!(name: "Harbour Lunch", document: row, enriched_description: "Lunches.")
      added = Source.form_entry_source.services.create!(name: "Breakfast Club", description: "Breakfasts.")
      web = source.documents.create!(title: "Web page", content: "Shelter info")
      message.rag_services = [added, imported]
      message.rag_documents = [web]

      references = helper.message_references(message)

      expect(references.map(&:key)).to eq(["s#{added.id}", "s#{imported.id}", web.id.to_s])
      expect(references.map(&:title)).to eq(["Breakfast Club", "Harbour Lunch", "Web page"])
      expect(references.map(&:text)).to eq(["Breakfasts.", "Lunches.", "Shelter info"])
      expect(references.map(&:report_document)).to eq([nil, row, web])
    end

    it "reads references a page loaded with the message, in the order chat found them" do
      first = Source.form_entry_source.services.create!(name: "Breakfast Club")
      second = Source.form_entry_source.services.create!(name: "Arts Drop-in")
      message.rag_services = [second, first]
      loaded = Message.includes(rag_documents: [:source, :service], rag_services: [:source, :document]).find(message.id)

      queries = []
      titles = ActiveSupport::Notifications.subscribed(->(*, payload) { queries << payload[:sql] }, "sql.active_record") do
        helper.message_references(loaded).map(&:title)
      end

      expect(titles).to eq(["Arts Drop-in", "Breakfast Club"])
      expect(queries).to be_empty
    end
  end

  describe "#reference_title" do
    let(:document) { Document.new(title: "Imported row") }

    it "uses the name of the service read from the reference" do
      document.build_service(name: "Community lunch")
      expect(helper.reference_title(document)).to eq("Community lunch")
    end

    it "uses the reference's own title when it has no service" do
      expect(helper.reference_title(document)).to eq("Imported row")
      expect(helper.reference_title(Document.new)).to eq("Untitled reference")
    end
  end

  describe "#reference_source_url" do
    ["https://example.com/resources?q=food", "http://example.com/resources"].each do |url|
      it "links to #{url}" do
        expect(helper.reference_source_url(Source.new(url: url))).to eq(url)
      end
    end

    [nil, "", "javascript:alert(1)", "data:text/html,test", "/resources", "https://", "https://invalid host"].each do |url|
      it "does not link to #{url.inspect}" do
        expect(helper.reference_source_url(Source.new(url: url))).to be_nil
      end
    end
  end
end
