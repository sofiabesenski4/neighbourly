require "rails_helper"
require "pdf/reader"

RSpec.describe "Flyers", type: :system do
  let!(:food) { Category.create!(name: "Meals") }
  let!(:shelter) { Category.create!(name: "Shelters") }
  let!(:harm_reduction) { Category.create!(name: "Harm Reduction Resources") }
  let(:site_url) { URI.join(page.current_url, root_path).to_s }

  before do
    driven_by(:rack_test)
  end

  it "shows both printout paths in the header and links to the questionnaire" do
    visit new_flyer_path

    expect(page).to have_css("h1", text: "Choose how to build your printout")
    within("header nav[aria-label='Printout view']") do
      expect(page).to have_css('[aria-current="page"]', text: "Build guide manually")
      expect(page).to have_text("Get a tailored list after a short questionnaire.")
      expect(page).to have_text("Search, filter, and select resources yourself.")
      expect(page).to have_link("Answer a few questions", href: find_help_for_myself_path)
    end
  end

  it "lets a visitor choose categories and request a flyer from the home page" do
    visit root_path
    click_link "Create printout"

    expect(FlyerGenerator).to receive(:call).with(
      categories: contain_exactly(food.id.to_s, harm_reduction.id.to_s),
      origin: nil,
      site_url: site_url,
      text_size_px: 15.5
    ).and_return(nil)

    uncheck "Shelters"
    click_button "Generate printout"

    expect(page).to have_content("No resources matched those categories")
  end

  it "lets a visitor print the complete guide without selecting filters" do
    visit new_flyer_path
    expect(page).to have_checked_field("Meals")
    expect(page).to have_checked_field("Shelters")

    expect(FlyerGenerator).to receive(:call).with(
      categories: [],
      origin: nil,
      site_url: site_url,
      text_size_px: 15.5
    ).and_return("%PDF-all-resources")

    click_button "Generate printout"

    expect(page.response_headers["Content-Type"]).to include("application/pdf")
    expect(page.body).to eq("%PDF-all-resources")
  end

  it "prints selected detail fields without opening a distance screen" do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
    Source.create!(name: "Local", source_type: "csv").services.create!(name: "Community meal", hours: "Weekdays",
      address_attributes: {lat: 48.43, lng: -123.36})

    visit new_flyer_path
    expect(page).to have_no_text("Where should we measure distances from?")
    expect(page).to have_no_text("Distances won't be shown on your printout.")
    expect(page).to have_no_field("Enter a place")
    click_button "Generate printout"

    text = PDF::Reader.new(StringIO.new(page.body)).pages.map(&:text).join("\n").gsub(/\s+/, " ")
    expect(text).to include("Hours: Weekdays")
    expect(text).not_to include("Distances are from", "Distance:")
  end

  it "shows responsive Tailwind filter controls without the builder stylesheet" do
    visit new_flyer_path

    filters = find('aside[aria-label="Resource filters"]')
    expect(filters[:class].split).to include("rounded-xl", "border-stone-200")
    expect(first('label:has(input[data-flyer-builder-target="category"])')[:class].split).to include("has-checked:bg-sage-100")
    expect(page).to have_no_css('link[href*="flyer_builder"]', visible: :all)
  end
end
