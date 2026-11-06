require "rails_helper"

# Tests the distance calculation behind the printout's distances and walking times.
# The expected values come from geometry: one degree of latitude is about 111.19 km
# anywhere on Earth, and a degree of longitude shrinks with the cosine of the latitude.
RSpec.describe GeoPoint do
  describe "#distance_km_to" do
    it "measures a degree of latitude" do
      distance = described_class.new(lat: 48, lng: -123).distance_km_to(described_class.new(lat: 49, lng: -123))

      expect(distance).to be_within(0.01).of(111.19)
    end

    it "accounts for longitude lines getting closer together further north" do
      distance = described_class.new(lat: 48.43, lng: -123).distance_km_to(described_class.new(lat: 48.43, lng: -122))

      expect(distance).to be_within(0.01).of(73.78)
    end

    it "gives the same distance in both directions" do
      pandora = described_class.new(lat: 48.4271129, lng: -123.3577635)
      admirals = described_class.new(lat: 48.4284587, lng: -123.4174225)

      expect(pandora.distance_km_to(admirals)).to be_within(0.001).of(admirals.distance_km_to(pandora))
      expect(pandora.distance_km_to(admirals)).to be_within(0.1).of(4.4)
    end

    it "is zero between the same point" do
      point = described_class.new(lat: 48.42, lng: -123.35)

      expect(point.distance_km_to(point)).to eq(0)
    end
  end
end
