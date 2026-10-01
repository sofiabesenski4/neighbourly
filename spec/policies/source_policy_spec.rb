require "rails_helper"

RSpec.describe SourcePolicy do
  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", admin: false) }
  let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }

  describe "admin user" do
    subject { described_class.new(admin, source) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_new }
    it { is_expected.to be_create }
    it { is_expected.to be_destroy }
  end

  describe "regular user" do
    subject { described_class.new(regular_user, source) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_new }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_destroy }
  end

  describe "guest (nil user)" do
    subject { described_class.new(nil, source) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_new }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_destroy }
  end

  describe "Scope" do
    before { source } # ensure created

    it "returns all sources for admin" do
      scope = described_class::Scope.new(admin, Source).resolve
      expect(scope).to include(source)
    end

    it "returns nothing for regular user" do
      scope = described_class::Scope.new(regular_user, Source).resolve
      expect(scope).to be_empty
    end

    it "returns nothing for guest" do
      scope = described_class::Scope.new(nil, Source).resolve
      expect(scope).to be_empty
    end
  end
end
