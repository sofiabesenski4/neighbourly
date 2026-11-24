require "rails_helper"

# Covers reading a service's details as values: every format they're saved in today, and
# that anything unclear is nil. How filters use them is in spec/models/questionnaire_spec.rb.
RSpec.describe ResourceAttributes do
  def ages(details)
    described_class.new(Service.new(name: "Drop-in", additional_details: details)).age_range
  end

  # docs/service-details.md is what people saving services read.
  it "documents every name it looks under" do
    documentation = Rails.root.join("docs/service-details.md").read

    described_class::NAMES.each_key { |name| expect(documentation).to include("`#{name}`") }
    described_class::AGE_HEADERS.each { |header| expect(documentation).to include("`#{header.titleize}`") }
  end

  describe ".any_known?" do
    let(:source) { Source.create!(name: "Local guide", source_type: "csv") }

    def service(details, **attributes)
      source.services.create!(name: "Drop-in", additional_details: details, **attributes)
    end

    it "is false with no services, or none that say" do
      expect(described_class.any_known?("age_range")).to be(false)

      service({})
      service({"ages" => "youth"})
      expect(described_class.any_known?("age_range")).to be(false)
    end

    it "is false when the only services that say are closed or were removed" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
      row = source.documents.create!(title: "Removed", content: "Removed")
      row.reports.create!(reason: "out of date", status: "valid")
      service({"ages" => "19+"}, document: row)
      service({"ages" => "19+"}, closed: true)

      expect(described_class.any_known?("age_range")).to be(false)
    end

    it "is true once one visible service says" do
      service({"ages" => "youth"})
      service({"ages" => "19+"})

      expect(described_class.any_known?("age_range")).to be(true)
    end

    it "reads only the details it lists" do
      expect { described_class.any_known?("destroy") }.to raise_error(KeyError)
    end

    it "lists every detail it can read" do
      expect(described_class::NAMES.values).to match_array(described_class.public_instance_methods(false))
    end
  end

  # What imports really save, so a change to the importer can't quietly break this. The
  # resource form is in spec/requests/documents_spec.rb.
  describe "a CSV import" do
    def imported_ages(header, value)
      allow_any_instance_of(ContentPipeline::Fetcher).to receive(:call).and_return("id,Name,#{header}\n1,Drop-in,#{value}\n")
      allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
      source = Source.create!(name: "#{header} list", url: "https://example.com/list.csv", source_type: "csv")
      ContentPipeline::Ingester.new(source).call
      described_class.new(source.services.sole).age_range
    end

    it "is found under each documented column name, however it's written" do
      ["Ages", "Age", "Age Range", "AGE_RANGE", "age-range"].each do |header|
        expect(imported_ages(header, "15-25")).to eq(15..25), "for #{header}"
      end
    end

    it "isn't found under any other column name" do
      ["Age Group", "Ages Served", "Min Age", "Notes"].each do |header|
        expect(imported_ages(header, "15-25")).to be_nil, "for #{header}"
      end
    end
  end

  describe "#age_range" do
    it "reads the resource form's numbers" do
      expect(ages("age_range" => {"min" => 13, "max" => 18})).to eq(13..18)
      expect(ages("age_range" => {"min" => 19, "max" => nil})).to eq(19..)
      expect(ages("age_range" => {"min" => nil, "max" => 18})).to eq(0..18)
      expect(ages("age_range" => {"min" => 19})).to eq(19..)
      expect(ages("age_range" => {"max" => 18})).to eq(0..18)
      expect(ages("age_range" => {"min" => 0, "max" => 5})).to eq(0..5)
      expect(ages("age_range" => {"min" => "13", "max" => "18"})).to eq(13..18)
      expect(ages("age_range" => {"min" => "", "max" => "18"})).to eq(0..18)
    end

    it "reads a CSV's own column" do
      expect(ages("Ages" => "15-25")).to eq(15..25)
      expect(ages("AGES" => " 15 – 25 ")).to eq(15..25)
      expect(ages("Age" => "15 to 25")).to eq(15..25)
      expect(ages("Age Range" => "08-12")).to eq(8..12)
    end

    it "reads what AI enrichment saves" do
      expect(ages("ages" => "19+")).to eq(19..)
      expect(ages("ages" => "12-18")).to eq(12..18)
    end

    it "is nil when nothing is saved" do
      [{}, {"ages" => ""}, {"ages" => nil}, {"age_range" => {}}, {"age_range" => {"min" => nil, "max" => nil}},
        {"age_range" => {"min" => "", "max" => ""}}].each do |details|
        expect(ages(details)).to be_nil, "for #{details}"
      end
    end

    it "is nil when the text is unclear, without guessing" do
      ["youth", "all ages", "19", "adults 19+", "19+ (some exceptions)", "13-18, 25+", "1990-2000", "25-15", "-5", "19.5+",
        "about 19+", "about 15-25", "19 and over", "under 19", "varies"].each do |text|
        expect(ages("ages" => text)).to be_nil, "for #{text}"
      end
    end

    it "is nil when the numbers don't make sense" do
      [{"min" => 25, "max" => 15}, {"min" => -1, "max" => 5}, {"min" => "young", "max" => 25}, {"min" => 19.5, "max" => nil},
        {"min" => 13, "max" => "old"},
        {"min" => [19], "max" => nil}].each do |range|
        expect(ages("age_range" => range)).to be_nil, "for #{range}"
      end
    end

    it "is nil for values that aren't text or a range" do
      [19, true, ["13-18"], [{"min" => 1}]].each { |value| expect(ages("ages" => value)).to be_nil, "for #{value}" }
    end

    it "skips a form range left blank, as the card does" do
      expect(ages("age_range" => {"min" => nil, "max" => nil}, "ages" => "19+")).to eq(19..)
    end

    it "is nil when the detail the card shows is unclear, even if another is clear" do
      expect(ages("age_range" => "varies", "ages" => "19+")).to be_nil
    end

    it "doesn't read ages from other details" do
      expect(ages("notes" => "19+", "eligibility" => "15-25", "gender" => ["all"])).to be_nil
    end
  end
end
