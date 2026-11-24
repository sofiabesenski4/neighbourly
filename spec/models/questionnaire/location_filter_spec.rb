require "rails_helper"

# Covers what a place adds to the search. The order that gives is in
# spec/models/questionnaire_spec.rb.
RSpec.describe Questionnaire::LocationFilter do
  it "sorts by distance from a place whose location is known" do
    origin = FlyerOrigin.new(label: "919 Pandora Ave", point: GeoPoint.new(lat: 48.42, lng: -123.36))

    expect(described_class.new(origin).search_options).to eq(origin: origin, sort: "distance")
  end

  it "changes nothing when the place couldn't be looked up" do
    expect(described_class.new(FlyerOrigin.new(label: "919 Pandora Ave", point: nil)).search_options).to eq({})
  end
end
