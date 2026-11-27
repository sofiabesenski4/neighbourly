require "rails_helper"

# Covers reading a typed place, looking it up, and the fields that carry it to other screens.
# The lookup itself is FlyerOrigin's, with its own spec, and is faked here.
RSpec.describe Questionnaire::LocationAnswer do
  let(:looked_up) { {"near" => "919 Pandora Ave", "checked" => "919 Pandora Ave", "lat" => "48.4201", "lng" => "-123.3601"} }

  describe ".read" do
    it "treats nothing typed as skipped" do
      [nil, {}, {"near" => ""}, {"near" => "  "}, {"checked" => "x", "lat" => "48"}].each do |submitted|
        answer = described_class.read(submitted)

        expect(answer).to be_valid
        expect(answer).not_to be_answered
        expect(answer.fields).to be_empty
      end
    end

    it "trims what was typed, and needs to look it up" do
      answer = described_class.read("near" => " 919 Pandora Ave ")

      expect(answer.text).to eq("919 Pandora Ave")
      expect(answer).to be_lookup_needed
      expect(answer).not_to be_located
    end

    it "uses coordinates from an earlier lookup of the same place, rounded to about 100 m" do
      answer = described_class.read(looked_up)

      expect(answer.point).to eq(GeoPoint.new(lat: 48.42, lng: -123.36))
      expect(answer).not_to be_lookup_needed
    end

    it "ignores coordinates that are for another place" do
      answer = described_class.read(looked_up.merge("near" => "1 Fort St"))

      expect(answer).not_to be_located
      expect(answer).to be_lookup_needed
    end

    it "ignores coordinates that aren't usable" do
      [{"lat" => "north"}, {"lat" => "91"}, {"lng" => "NaN"}, {"lat" => "Infinity"}, {"lat" => ""}].each do |bad|
        expect(described_class.read(looked_up.merge(bad))).not_to be_located, "for #{bad}"
      end
    end

    it "refuses anything that isn't a set of text fields" do
      ["919 Pandora Ave", ["near"], {"near" => ["x"]}, {"near" => {"a" => "b"}}].each do |submitted|
        expect(described_class.read(submitted).problem).to eq(:unreadable), "for #{submitted}"
      end
    end

    it "refuses text too long to be a place, without looking it up" do
      answer = described_class.read("near" => "a" * 201)

      expect(answer.problem).to eq(:too_long)
      expect(answer).not_to be_lookup_needed
      expect(described_class.read("near" => "a" * 200)).to be_valid
    end
  end

  # What device_location_controller.js fills in.
  describe "a device's location" do
    let(:device) { {"near" => "", "device" => "1", "checked" => "", "lat" => "48.42011", "lng" => "-123.3601"} }

    it "uses the coordinates, rounded to about 100 m, with no lookup" do
      answer = described_class.read(device)

      expect(answer).to be_answered
      expect(answer.point).to eq(GeoPoint.new(lat: 48.42, lng: -123.36))
      expect(answer).not_to be_lookup_needed
      expect(FlyerOrigin).not_to receive(:locate)
      expect(answer.resolve).to eq(answer)
    end

    it "is called your location" do
      expect(described_class.read(device).value)
        .to eq(FlyerOrigin.new(label: "your location", point: GeoPoint.new(lat: 48.42, lng: -123.36)))
    end

    it "gives way to a typed place, and its coordinates aren't used for it" do
      answer = described_class.read(device.merge("near" => "919 Pandora Ave"))

      expect(answer.device).to be(false)
      expect(answer).not_to be_located
      expect(answer).to be_lookup_needed
    end

    it "is refused when the coordinates aren't usable" do
      [{"lat" => "north"}, {"lat" => "91"}, {"lng" => ""}, {"lng" => "NaN"}].each do |bad|
        expect(described_class.read(device.merge(bad)).problem).to eq(:device), "for #{bad}"
      end
    end

    it "is skipped when the coordinates come without saying what they're for" do
      expect(described_class.read(device.merge("device" => ""))).not_to be_answered
    end
  end

  describe "#resolve" do
    let(:typed) { described_class.read("near" => "919 Pandora Ave") }

    it "rounds the point it finds to about 100 m" do
      allow(FlyerOrigin).to receive(:locate).with("919 Pandora Ave")
        .and_return(FlyerOrigin.new(label: "919 Pandora Ave", point: GeoPoint.new(lat: 48.42678, lng: -123.35912)))

      expect(typed.resolve.point).to eq(GeoPoint.new(lat: 48.427, lng: -123.359))
    end

    it "remembers that the address service was down, so other screens don't try again" do
      allow(FlyerOrigin).to receive(:locate).and_return(FlyerOrigin.new(label: "919 Pandora Ave", point: nil))
      answer = typed.resolve

      expect(answer).to be_valid
      expect(answer).not_to be_located
      expect(answer).not_to be_lookup_needed
    end

    it "is invalid when the place isn't found" do
      allow(FlyerOrigin).to receive(:locate).and_return(nil)

      expect(typed.resolve.problem).to eq(:not_found)
    end
  end

  describe "#fields" do
    # As the browser would send them back.
    def resubmitted(answer)
      answer.fields.to_h { |suffix, value| [suffix.delete("[]"), value.to_s] }
    end

    it "carries a place that has been looked up" do
      answer = described_class.read(looked_up)

      expect(described_class.read(resubmitted(answer))).to eq(answer)
    end

    it "carries a device's location" do
      answer = described_class.read("device" => "1", "lat" => "48.42", "lng" => "-123.36")

      expect(described_class.read(resubmitted(answer))).to eq(answer)
    end

    it "carries a place that hasn't been looked up, or whose lookup failed" do
      [described_class.new(text: "919 Pandora Ave"), described_class.new(text: "919 Pandora Ave", checked: true)].each do |answer|
        expect(described_class.read(resubmitted(answer))).to eq(answer)
      end
    end
  end
end
