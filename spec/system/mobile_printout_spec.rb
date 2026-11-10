require "rails_helper"
require "pdf/reader"

RSpec.describe "Mobile printouts", type: :system do
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:health) { Category.create!(name: "Health Care") }

  before do
    driven_by(:selenium_chrome_headless)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
    allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.42, lng: -123.36))
    source = Source.create!(name: "Victoria Community Directory", source_type: "api")
    source.documents.create!(title: "Farther kitchen", content: "Meals", categories: [meals], metadata: {lat: 48.44, lng: -123.36})
    source.documents.create!(title: "Nearby kitchen", content: "Meals", categories: [meals], metadata: {lat: 48.421, lng: -123.36})
    source.documents.create!(title: "Community clinic", content: "Health care", categories: [health], metadata: {lat: 48.425, lng: -123.36})
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    page.current_window.resize_to(1280, 900)
  end

  def tap(control)
    control.execute_script("this.scrollIntoView({block: 'center'})")
    actions = page.driver.browser.action
    actions.add_pointer_input(:touch, "finger")
    actions.move_to(control.native, device: "finger")
      .pointer_down(:left, device: "finger")
      .pointer_up(:left, device: "finger")
      .perform
  end

  [[320, 740], [844, 390]].each do |width, height|
    it "filters, sorts, rotates, and opens a mapped PDF at #{width} by #{height}" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: true)
      visit new_flyer_path
      expect(find_field("Enter a place").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      fill_in "Enter a place", with: "919 Pandora Ave"
      click_button "Continue"
      expect(page).to have_css("article h4", count: 3)

      if width < 640
        find("button[aria-label='Filters']").click
        within("#flyer-filters[open]") do
          check "Meals"
          select "Distance", from: "Sort by"
          click_button "Apply filters"
        end
      else
        sort = find("summary[aria-label='Sort resources']")
        expect(sort.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
        tap(sort)
        expect(find_button("Distance").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
        click_button "Distance"
        check "Meals"
      end
      expect(page).to have_css("article h4", count: 2)
      expect(all("article h4").map(&:text)).to eq(["Nearby kitchen", "Farther kitchen"])
      fill_in "Search resources", with: "kitchen"
      expect(page).to have_css("h2#flyer-preview-heading", exact_text: "2 resources included")

      rotated_width, rotated_height = (width < 640) ? [844, 390] : [390, 740]
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: rotated_width, height: rotated_height, deviceScaleFactor: 1, mobile: true)
      expect(page).to have_field("Search resources", with: "kitchen")
      expect(find_field("Search resources").evaluate_script("parseFloat(getComputedStyle(this).fontSize)")).to be >= 16
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(all("article h4").map(&:text)).to eq(["Nearby kitchen", "Farther kitchen"])

      page.execute_script <<~JS
        const createObjectURL = URL.createObjectURL.bind(URL);
        URL.createObjectURL = blob => {
          window.capturedMobilePrintout = blob;
          return createObjectURL(blob);
        };
      JS
      expect(find_button("Generate printout").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      printout = window_opened_by { click_button "Generate printout" }
      expect(page).to have_link("Open printout", href: /\Ablob:/)
      pdf_url = find_link("Open printout")[:href]
      within_window(printout) { expect(page).to have_current_path(pdf_url, url: true) }

      data_url = page.evaluate_async_script(<<~JS)
        const done = arguments[0];
        const reader = new FileReader();
        reader.onload = () => done(reader.result);
        reader.readAsDataURL(window.capturedMobilePrintout);
      JS
      pdf = PDF::Reader.new(StringIO.new(data_url.split(",", 2).last.unpack1("m")))
      expect(pdf.pages.first.text.scan(/(?:Nearby|Farther) kitchen/)).to eq(["Nearby kitchen", "Farther kitchen"])
      expect(pdf.pages.last.text).to include("Map", "OpenStreetMap contributors")
      expect(pdf.pages.map(&:text).join("\n")).not_to include("Community clinic")
    ensure
      printout&.close
    end
  end
end
