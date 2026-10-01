require "rails_helper"

RSpec.describe DocumentPolicy do
  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", admin: false) }
  let(:source) { Source.form_entry_source }
  let(:document) {
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    source.documents.create!(content: "test", title: "Test Resource")
  }

  describe "admin user" do
    subject { described_class.new(admin, document) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_new }
    it { is_expected.to be_create }
    it { is_expected.to be_edit }
    it { is_expected.to be_update }
    it { is_expected.to be_destroy }
  end

  describe "regular user" do
    subject { described_class.new(regular_user, document) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_new }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_edit }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  describe "guest (nil user)" do
    subject { described_class.new(nil, document) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_new }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_edit }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  describe "Scope" do
    before do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    end

    let!(:form_document) { source.documents.create!(content: "form doc", title: "Form Resource") }
    let!(:api_source) { Source.create!(name: "API", url: "https://example.com", source_type: "api") }
    let!(:api_document) { api_source.documents.create!(content: "api doc", external_id: "1") }

    it "returns only form-source documents for admin" do
      scope = described_class::Scope.new(admin, Document).resolve
      expect(scope).to include(form_document)
      expect(scope).not_to include(api_document)
    end

    it "returns nothing for regular user" do
      scope = described_class::Scope.new(regular_user, Document).resolve
      expect(scope).to be_empty
    end

    it "returns nothing for guest" do
      scope = described_class::Scope.new(nil, Document).resolve
      expect(scope).to be_empty
    end
  end
end
