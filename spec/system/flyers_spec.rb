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
    uncheck "Shelter & housing"
    check "Harm reduction"
    click_button "Generate printout"

    expect(page).to have_content("No resources matched those categories")
  end

  it "lets a visitor print the complete guide after clearing the default filters" do
    expect(FlyerGenerator).to receive(:call).with(categories: []).and_return("%PDF-all-resources")

    visit new_flyer_path
    uncheck "Food"
    uncheck "Shelter & housing"
    click_button "Generate printout"

    expect(page.response_headers["Content-Type"]).to include("application/pdf")
    expect(page.body).to eq("%PDF-all-resources")
  end
end
