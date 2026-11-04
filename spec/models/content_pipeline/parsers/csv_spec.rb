require "rails_helper"

RSpec.describe ContentPipeline::Parsers::Csv do
  let(:source) { Source.new(name: "Drop-in Centres", source_type: "csv") }
  let(:parser) { described_class.new(source) }

  describe "#parse" do
    let(:csv) do
      <<~CSV
        Program Name,Address,Phone,Notes
        Harbour Meals,100 Harbour St,250-555-0100,"Hot lunch, weekdays"
        Northside Shelter,22 North Rd,,Open 24 hours
      CSV
    end

    it "returns one chunk per row" do
      expect(parser.parse(csv).size).to eq(2)
    end

    it "stores every header/value pair in metadata" do
      chunk = parser.parse(csv).first

      expect(chunk[:metadata]).to eq(
        "Program Name" => "Harbour Meals",
        "Address" => "100 Harbour St",
        "Phone" => "250-555-0100",
        "Notes" => "Hot lunch, weekdays"
      )
    end

    it "keeps blank cells in metadata as nil" do
      chunk = parser.parse(csv).second

      expect(chunk[:metadata]).to include("Phone" => nil)
    end

    it "renders present values as Header: value lines in the content" do
      chunk = parser.parse(csv).second

      expect(chunk[:content]).to eq("Program Name: Northside Shelter\nAddress: 22 North Rd\nNotes: Open 24 hours")
    end

    it "uses a name or title column for the title" do
      expect(parser.parse(csv).map { |chunk| chunk[:title] }).to eq(["Harbour Meals", "Northside Shelter"])
    end

    it "falls back to the first present value for the title" do
      chunk = parser.parse("Address,Phone\n,250-555-0100\n").first

      expect(chunk[:title]).to eq("250-555-0100")
    end

    it "assigns no categories" do
      expect(parser.parse(csv).first[:categories]).to eq([])
    end

    describe "external_id" do
      it "uses an id column when present" do
        chunk = parser.parse("ID,Name\n42,Harbour Meals\n").first

        expect(chunk[:external_id]).to eq("42")
      end

      it "hashes the row when there is no id column" do
        first, second = parser.parse(csv)

        expect(first[:external_id]).to match(/\A\h{64}\z/)
        expect(first[:external_id]).not_to eq(second[:external_id])
      end

      it "is stable across parses of the same file" do
        expect(parser.parse(csv).map { |c| c[:external_id] }).to eq(parser.parse(csv).map { |c| c[:external_id] })
      end

      it "keeps only the last row when rows share an external_id" do
        chunks = parser.parse("id,Name\n1,Old Name\n2,Other\n1,New Name\n")

        expect(chunks.map { |c| c[:title] }).to eq(["New Name", "Other"])
      end
    end

    it "names blank headers by position and suffixes duplicate headers" do
      chunk = parser.parse("Name,,Phone,Phone\nHarbour Meals,x,111,222\n").first

      expect(chunk[:metadata].keys).to eq(["Name", "column_2", "Phone", "Phone (2)"])
      expect(chunk[:metadata]).to include("Phone" => "111", "Phone (2)" => "222")
    end

    it "keeps cells beyond the last header under positional names" do
      chunk = parser.parse("Name\nHarbour Meals,extra\n").first

      expect(chunk[:metadata]).to eq("Name" => "Harbour Meals", "column_2" => "extra")
    end

    it "skips rows with no values" do
      expect(parser.parse("Name,Phone\n,\nHarbour Meals,111\n , \n").size).to eq(1)
    end

    it "returns no chunks for a header-only file" do
      expect(parser.parse("Name,Phone\n")).to eq([])
    end

    it "strips a UTF-8 byte order mark from the first header" do
      chunk = parser.parse("﻿Name,Phone\nHarbour Meals,111\n".b).first

      expect(chunk[:metadata].keys.first).to eq("Name")
    end

    it "reads Windows-1252 files saved from Excel" do
      chunk = parser.parse("Name\nCaf\xE9 Esperanza\n".b).first

      expect(chunk[:title]).to eq("Café Esperanza")
    end

    it "raises a ParseError for malformed CSV" do
      expect { parser.parse("Name,Notes\nHarbour,\"unclosed\n") }
        .to raise_error(ContentPipeline::Parsers::ParseError, /could not be read as CSV/)
    end
  end
end
