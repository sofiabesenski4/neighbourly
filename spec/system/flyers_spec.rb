require "rails_helper"

RSpec.describe "Flyers", type: :system do
  before do
    driven_by(:rack_test)
  end

  it "lets a visitor choose categories and request a flyer from the home page" do
    expect(FlyerGenerator).to receive(:call).with(categories: ["food", "harm_reduction"]).and_return(nil)

    visit root_path
    click_link "Make a printable flyer"

    check "Food"
    check "Harm reduction"
    click_button "Generate printout"

    expect(page).to have_content("No resources matched those categories")
  end

  it "lets a visitor print the complete guide without selecting filters" do
    expect(FlyerGenerator).to receive(:call).with(categories: []).and_return("%PDF-all-resources")

    visit new_flyer_path
    expect(page).not_to have_checked_field("Food")
    expect(page).not_to have_checked_field("Shelter & housing")
    click_button "Generate printout"

    expect(page.response_headers["Content-Type"]).to include("application/pdf")
    expect(page.body).to eq("%PDF-all-resources")
  end

  it "shows responsive Tailwind filter controls without the builder stylesheet" do
    visit new_flyer_path

    filters = find('aside[aria-label="Resource filters"]')
    expect(filters[:class].split).to include("rounded-xl", "border-stone-200")
    expect(first('label:has(input[data-flyer-builder-target="category"])')[:class].split).to include("has-checked:bg-sage-100")
    expect(page).to have_no_css('link[href*="flyer_builder"]', visible: :all)
  end
end
