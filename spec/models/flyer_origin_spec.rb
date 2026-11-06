require "rails_helper"

# Tests turning what someone typed into a place to measure from, including the three
# outcomes the controller depends on. Geocoder is replaced with a fake because
# geocoder_spec.rb covers it. The expected queries reflect how the real service
# scored these forms of address.
RSpec.describe FlyerOrigin do
  let(:point) { GeoPoint.new(lat: 48.4263, lng: -123.3649) }

  describe ".locate" do
    it "returns an origin that can measure distances when the place is found" do
      allow(Geocoder).to receive(:locate).and_return(point)

      origin = described_class.locate("Douglas St and Yates St")

      expect(origin.label).to eq("Douglas St and Yates St")
      expect(origin.point).to eq(point)
      expect(origin).to be_located
    end

    it "returns nothing when there is no trustworthy match" do
      allow(Geocoder).to receive(:locate).and_return(nil)

      expect(described_class.locate("Central Library")).to be_nil
    end

    it "returns an origin with no location when the geocoder is down" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable, "HTTP 503")

      origin = described_class.locate("919 Pandora Ave")

      expect(origin.label).to eq("919 Pandora Ave")
      expect(origin).not_to be_located
    end

    # This may be someone's home address, so it must stay out of error reports.
    it "reports an outage without including what was typed" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable, "HTTP 503")

      expect(Rails.error).to receive(:report)
        .with(instance_of(Geocoder::Unavailable), context: {feature: "flyer_origin"})

      described_class.locate("919 Pandora Ave")
    end
  end

  describe ".query_for" do
    it "assumes Victoria when no city is given" do
      expect(described_class.query_for("919 Pandora Ave")).to eq("919 Pandora Ave, Victoria, BC")
    end

    it "keeps a city the person typed" do
      expect(described_class.query_for("500 Admirals Rd, Esquimalt")).to eq("500 Admirals Rd, Esquimalt, BC")
    end

    it "doesn't repeat the province" do
      expect(described_class.query_for("919 Pandora Ave, Victoria, BC")).to eq("919 Pandora Ave, Victoria, BC")
      expect(described_class.query_for("919 Pandora Ave, bc")).to eq("919 Pandora Ave, Victoria, BC")
    end
  end
end
