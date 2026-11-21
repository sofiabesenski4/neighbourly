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

    it "reads the address from columns it recognises, keeping the row whole in metadata" do
      chunks = parser.parse(csv)

      expect(chunks.first[:address]).to eq(
        street_address: "100 Harbour St", city: nil, province: nil, postal_code: nil, country: nil,
        phone: "250-555-0100", lat: nil, lng: nil
      )
      expect(chunks.first[:metadata]).to include("Address" => "100 Harbour St", "Phone" => "250-555-0100")
      expect(chunks.last[:address]).to include(street_address: "22 North Rd", phone: nil)
    end

    it "recognises address columns whatever their spelling" do
      chunk = parser.parse("Name,STREET_ADDRESS,Town,Phone Number,Latitude,Longitude\nHarbour,1 Main St,Sidney,250-555-0100,48.6,-123.4\n").first

      expect(chunk[:address]).to eq(
        street_address: "1 Main St", city: "Sidney", province: nil, postal_code: nil, country: nil,
        phone: "250-555-0100", lat: "48.6", lng: "-123.4"
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

    it "only takes the title from a column named name or title as a whole word" do
      chunks = parser.parse("Filename,Username,program_name,Job Title\nexport.csv,jdoe,Harbour Meals,Cook\nexport.csv,jdoe,,Cook\n")

      expect(chunks.map { |chunk| chunk[:title] }).to eq(["Harbour Meals", "Cook"])
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

    it "never gives a generated header the name of a header in the file" do
      chunk = parser.parse("Name,Name,Name (2),,column_4\nA,B,C,D,E\n").first

      expect(chunk[:metadata]).to eq(
        "Name" => "A", "Name (3)" => "B", "Name (2)" => "C", "column_4 (2)" => "D", "column_4" => "E"
      )
    end

    it "never gives an extra cell the name of a header in the file" do
      chunk = parser.parse("Name,column_3\nA,B\nX,Y,Z\n").second

      expect(chunk[:metadata]).to eq("Name" => "X", "column_3" => "Y", "column_3 (2)" => "Z")
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

    describe "the service a row describes" do
      let(:csv) do
        "ID,Program Name,Organization Name,Description,Street Address,City,State,Zip,Country,Phone,E-mail,Website,Ages,Notes\n" \
          "7,Community Lunch,Harbourside Society,Hot lunch,100 Harbour St,Victoria,BC,V8W 1A1,Canada,250-555-0101," \
          "lunch@example.org,example.org/lunch,All ages,\n"
      end
      let(:chunk) { parser.parse(csv).first }

      it "fills the service's fields from the columns that match them" do
        expect(chunk[:service]).to include(
          name: "Community Lunch", description: "Hot lunch", phone: "250-555-0101",
          email: "lunch@example.org", website: "https://example.org/lunch"
        )
      end

      it "reads the whole address, which the resource and its service share" do
        expect(chunk[:address]).to include(
          street_address: "100 Harbour St", city: "Victoria", province: "BC", postal_code: "V8W 1A1", country: "Canada"
        )
        expect(chunk[:service]).not_to include(:street_address, :city, :province)
      end

      it "names the organization from its column, without taking it as the title" do
        expect(chunk[:organization]).to eq(name: "Harbourside Society")
        expect(chunk[:title]).to eq("Community Lunch")
      end

      it "keeps every other filled-in column in additional details" do
        expect(chunk[:service][:additional_details]).to eq("Ages" => "All ages")
      end

      # The row's first value is a stand-in title, not a name, so enrichment
      # names the service. It stays in the details unless another field used it.
      it "leaves the service unnamed when the row has no name or title column" do
        chunk = parser.parse("ID,Ages,Notes\n7,19+,Bring ID\n").first

        expect(chunk[:title]).to eq("7")
        expect(chunk[:service][:name]).to be_nil
        expect(parser.parse("Ages,Notes\n19+,Bring ID\n").first[:service][:additional_details]).to eq("Ages" => "19+", "Notes" => "Bring ID")
      end

      it "puts every phone column on the service's phone, rather than in additional details" do
        chunk = parser.parse("Name,Phone,Phone Number,Telephone\nHarbour Meals,111,222,111\n").first

        expect(chunk[:service][:phone]).to eq("111, 222")
        expect(chunk[:service][:additional_details]).to eq({})
      end

      it "puts a repeated phone header's number on the service's phone too" do
        chunk = parser.parse("Name,Phone,Phone\nHarbour Meals,111,222\n").first

        expect(chunk[:metadata]).to include("Phone" => "111", "Phone (2)" => "222")
        expect(chunk[:service][:phone]).to eq("111, 222")
        expect(chunk[:service][:additional_details]).to eq({})
      end

      it "keeps a website with no host in additional details" do
        ["https://?", "https://:443"].each do |website|
          chunk = parser.parse("Name,Website\nHarbour Meals,#{website}\n").first

          expect(chunk[:service]).not_to have_key(:website)
          expect(chunk[:service][:additional_details]).to eq("Website" => website)
        end
      end

      it "keeps a website that isn't a web address in additional details" do
        chunk = parser.parse("Name,Website\nHarbour Meals,ask at the desk\n").first

        expect(chunk[:service]).not_to have_key(:website)
        expect(chunk[:service][:additional_details]).to eq("Website" => "ask at the desk")
      end

      it "takes the street address from Address Line 1, keeping Address Line 2 as a detail" do
        chunk = parser.parse("Name,Address Line 2,Address Line 1\nHarbour Meals,Unit 4,100 Harbour St\n").first

        expect(chunk[:address][:street_address]).to eq("100 Harbour St")
        expect(chunk[:service][:additional_details]).to eq("Address Line 2" => "Unit 4")
      end

      it "names no organization when the row has no organization column" do
        expect(parser.parse("Name,Phone\nHarbour Meals,111\n").first[:organization]).to be_nil
      end
    end
  end
end
