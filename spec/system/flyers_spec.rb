require "rails_helper"
require "pdf/reader"

RSpec.describe "Flyers", type: :system do
  let!(:food) { Category.create!(name: "Meals") }
  let!(:shelter) { Category.create!(name: "Shelters") }
  let!(:harm_reduction) { Category.create!(name: "Harm Reduction Resources") }

  before do
    driven_by(:rack_test)
  end

  it "lets a visitor choose categories and request a flyer from the home page" do
    expect(FlyerGenerator).to receive(:call).with(categories: contain_exactly(food.id.to_s, harm_reduction.id.to_s), origin: nil).and_return(nil)

    visit root_path
    click_link "Make a printable flyer"

    check "Meals"
    check "Harm Reduction Resources"
    click_button "Generate printout"

    expect(page).to have_content("No resources matched those categories")
  end

  it "lets a visitor print the complete guide without selecting filters" do
    expect(FlyerGenerator).to receive(:call).with(categories: [], origin: nil).and_return("%PDF-all-resources")

    visit new_flyer_path
    expect(page).not_to have_checked_field("Meals")
    expect(page).not_to have_checked_field("Shelters")
    click_button "Generate printout"

    expect(page.response_headers["Content-Type"]).to include("application/pdf")
    expect(page.body).to eq("%PDF-all-resources")
  end

  # Uses the real form without JavaScript. The builder's JavaScript sends the same
  # form fields, and flyer_builder_controller.test.js covers its own behaviour.
  it "lets a visitor enter a location and get distances on the printout" do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    Source.create!(name: "Local", source_type: "api").documents.create!(
      title: "Community meal", content: "Community meal", metadata: {lat: 48.43, lng: -123.36}
    )
    allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.42, lng: -123.36))

    visit new_flyer_path
    fill_in "Near", with: "Douglas St and Yates St"
    click_button "Generate printout"

    text = PDF::Reader.new(StringIO.new(page.body)).pages.map(&:text).join("\n").gsub(/\s+/, " ")
    expect(text).to include("Distances are from Douglas St and Yates St", "Distance: 1.1 km")
  end

  it "lets a visitor correct a location that can't be found" do
    allow(Geocoder).to receive(:locate).and_return(nil)

    visit new_flyer_path
    fill_in "Near", with: "Central Library"
    click_button "Generate printout"

    expect(page).to have_content("We couldn't find that location")
    expect(page).to have_field("Near", with: "Central Library")
  end

  it "shows responsive Tailwind filter controls without the builder stylesheet" do
    visit new_flyer_path

    filters = find('aside[aria-label="Resource filters"]')
    expect(filters[:class].split).to include("rounded-xl", "border-stone-200")
    expect(first('label:has(input[data-flyer-builder-target="category"])')[:class].split).to include("has-checked:bg-sage-100")
    expect(page).to have_no_css('link[href*="flyer_builder"]', visible: :all)
  end
end
