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
    click_button "Generate flyer"

    expect(page).to have_content("Flyer generation is coming soon")
  end

  it "asks the visitor to choose something when nothing is selected" do
    visit new_flyer_path
    click_button "Generate flyer"

    expect(page).to have_content("must include at least one type of information")
  end
end
