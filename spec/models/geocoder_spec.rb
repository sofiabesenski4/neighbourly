require "rails_helper"

# Tests how Geocoder reads the BC Address Geocoder's replies and which matches it
# trusts. No real network requests happen: WebMock blocks them in tests, and each
# example supplies a fake reply with the same shape as the real service's. That
# keeps these tests fast and independent of the service being up, but it also
# means they can't notice if the real service changes its format.
RSpec.describe Geocoder do
  # Makes the next request to the service get this fake reply. Defaults to a
  # perfect match for 919 Pandora Ave, so each example only states what's different.
  def stub_geocoder(precision: "CIVIC_NUMBER", score: 100, coordinates: [-123.3577635, 48.4271129])
    stub_request(:get, Geocoder::ENDPOINT).with(query: hash_including({})).to_return(
      status: 200,
      body: {features: [{
        geometry: {type: "Point", coordinates: coordinates},
        properties: {score: score, matchPrecision: precision}
      }]}.to_json
    )
  end

  # Swapping these would put every pin in the wrong place, far outside BC.
  it "reads latitude and longitude from the service's longitude-first coordinates" do
    stub_geocoder

    expect(described_class.locate("919 Pandora Ave, Victoria, BC"))
      .to eq(GeoPoint.new(lat: 48.4271129, lng: -123.3577635))
  end

  it "asks for the single best match to the address" do
    stub_geocoder

    described_class.locate("919 Pandora Ave, Victoria, BC")

    expect(a_request(:get, Geocoder::ENDPOINT)
      .with(query: {addressString: "919 Pandora Ave, Victoria, BC", maxResults: "1"})).to have_been_made
  end

  # The real service returned BLOCK for 2916 Douglas St, one of the sample
  # resources, so requiring an exact building would wrongly drop it.
  it "accepts a match on the address's block or an intersection" do
    %w[BLOCK INTERSECTION].each do |precision|
      stub_geocoder(precision: precision)

      expect(described_class.locate("2916 Douglas St, Victoria, BC")).to be_a(GeoPoint)
    end
  end

  it "rejects a match that only found the street or town" do
    %w[STREET LOCALITY PROVINCE].each do |precision|
      stub_geocoder(precision: precision)

      expect(described_class.locate("Somewhere, Victoria, BC")).to be_nil
    end
  end

  # Based on a real reply: "123 Fake Street, Victoria, BC" scored 88 with
  # building-level precision, for a house on Salt Spring Island.
  it "rejects a building-level match with a low score" do
    stub_geocoder(score: 88)

    expect(described_class.locate("123 Fake Street, Victoria, BC")).to be_nil
  end

  # The lowest score seen for a correct match: an address with no city.
  it "accepts a match at the minimum score" do
    stub_geocoder(score: 90)

    expect(described_class.locate("919 Pandora Ave, BC")).to be_a(GeoPoint)
  end

  it "returns nothing when there are no matches" do
    stub_request(:get, Geocoder::ENDPOINT).with(query: hash_including({}))
      .to_return(status: 200, body: {features: []}.to_json)

    expect(described_class.locate("Nowhere")).to be_nil
  end

  # These need to raise rather than return nil. Nil means "no match, stop trying",
  # while Unavailable tells GeocodeDocumentJob to try again later.
  it "reports the service as unavailable on errors, timeouts and unreadable replies" do
    request = stub_request(:get, Geocoder::ENDPOINT).with(query: hash_including({}))

    request.to_return(status: 503)
    expect { described_class.locate("919 Pandora Ave") }.to raise_error(Geocoder::Unavailable)

    request.to_timeout
    expect { described_class.locate("919 Pandora Ave") }.to raise_error(Geocoder::Unavailable)

    request.to_return(status: 200, body: "<html>Maintenance</html>")
    expect { described_class.locate("919 Pandora Ave") }.to raise_error(Geocoder::Unavailable)
  end
end
