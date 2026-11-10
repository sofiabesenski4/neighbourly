require "rails_helper"
require "pdf/reader"

RSpec.describe "Live resource guide builder", type: :system do
  let!(:food) { Category.create!(name: "Meals") }
  let!(:health) { Category.create!(name: "Health Care") }
  let!(:legal) { Category.create!(name: "Legal Support") }

  before do
    driven_by(:selenium, using: :headless_chrome) do |options|
      options.add_argument("--no-sandbox")
      options.add_argument("--disable-dev-shm-usage")
    end

    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
    source = Source.create!(name: "Local", source_type: "api")
    source.documents.create!(title: "Alpha meals", content: "Meals", categories: [food])
    source.documents.create!(title: "Beta clinic", content: "Clinic", categories: [health])
    source.documents.create!(title: "Gamma noticeboard", content: "Noticeboard", metadata: {})
  end

  # Distance checks allow any space after the label. CI doesn't build the stylesheet, so there
  # the label and value land on separate lines, and that layout isn't what they're testing.
  # Most examples here are about the second screen, so they skip the location one.
  def visit_builder
    visit new_flyer_path
    click_button "Skip distances"
  end

  it "opens the generated PDF in a new tab with one click" do
    visit_builder
    expect(page).to have_button("Generate printout", disabled: false)

    printout = window_opened_by { click_button "Generate printout" }
    expect(page).to have_link("Open printout", href: /\Ablob:/)
    pdf_url = find_link("Open printout")[:href]
    within_window(printout) { expect(page).to have_current_path(pdf_url, url: true) }
  ensure
    printout&.close
  end

  it "offers the PDF link when the browser blocks the new tab" do
    visit root_path
    page.execute_script("window.flyerNavigationSentinel = true")

    find_link("Create printout").send_keys(:enter)
    click_button "Skip distances"

    expect(page).to have_css("nav a[aria-current='page']", text: "Printout")
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page.evaluate_script("window.flyerNavigationSentinel")).to be_nil
    page.execute_script("window.open = () => null")

    click_button "Generate printout"

    # The person opens the printout in a new tab. Nothing tries to print it from a frame,
    # and focus moves to the link so keyboard users can open it straight away.
    expect(page).to have_link("Open printout", href: /\Ablob:/)
    expect(find_link("Open printout")[:target]).to eq("_blank")
    expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Open printout")
    expect(page).to have_no_css("iframe", visible: :all)
    expect(page).to have_css('button[data-flyer-builder-target="generate"] svg[fill="none"][stroke="currentColor"]')
  end

  it "keeps the landing header visible on a narrow printout screen" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit new_flyer_path

    within("nav[aria-label='Main navigation']") do
      expect(page).to have_link("neighbourly", href: root_path)
      expect(page).to have_link("Chat", href: new_chat_path)
      expect(page).to have_link("Printout", href: new_flyer_path)
      expect(page).to have_link("Sign in", href: new_user_session_path)
      expect(page).not_to have_button("Open main menu")
      all("a").each do |link|
        expect(link.evaluate_script("this.getBoundingClientRect().left >= 0 && this.getBoundingClientRect().right <= window.innerWidth")).to be(true)
        expect(link.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      end
    end
    expect(page).to have_css("nav a[aria-current='page']", text: "Printout")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "updates cards and print availability when categories are selected and cleared" do
    visit_builder

    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "3 resources included")
    expect(page).to have_no_css("h3", text: "Legal Support")
    expect(page).to have_no_text("No matching resources in this category.")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Meals"
    expect(page).to have_css('button[data-flyer-builder-target="generate"] svg[fill="none"][stroke="currentColor"]')
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(page).to have_no_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "1 resource included")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Legal Support"
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "1 resource included")
    expect(page).to have_css("h3", text: "Meals")
    expect(page).to have_no_css("h3", text: "Legal Support")
    expect(page).to have_no_text("No matching resources in this category.")
    uncheck "Legal Support"

    check "Health Care"
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "2 resources included")

    uncheck "Meals"
    uncheck "Health Care"
    expect(page).to have_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "3 resources included")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Legal Support"
    expect(page).to have_text("No resources match the selected categories.")
    expect(page).to have_button("Generate printout", disabled: true)
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "0 resources included")
    expect(page).to have_no_css("h3")
  end

  it "fills the final row when a category has an odd number of cards" do
    source = Source.find_by!(name: "Local")
    source.documents.create!(title: "Bravo meals", content: "Meals", categories: [food])
    source.documents.create!(title: "Charlie meals", content: "Meals", categories: [food])
    page.current_window.resize_to(1280, 900)
    visit_builder

    section = find("h3", text: "Meals").ancestor("[data-flyer-builder-target='cards'] > section")
    cards = section.all("article", count: 3)
    widths = cards.map { |card| card.evaluate_script("this.getBoundingClientRect().width") }
    grid_width = cards.last.evaluate_script("this.parentElement.getBoundingClientRect().width")

    expect(widths[0]).to be_within(1).of(widths[1])
    expect(widths[2]).to be > widths[0]
    expect(widths[2]).to be_within(1).of(grid_width)
  end

  it "searches alongside desktop categories and keeps the query when switching to mobile" do
    visit_builder
    expect(page).to have_css("article h4", text: "Alpha meals")

    within("aside[aria-label='Resource filters']") do
      fill_in "Search resources", with: "clinic"
      find_field("Search resources").send_keys(:enter)
    end
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "1 resource included")
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_no_text("Alpha meals")
    check "Meals"
    expect(page).to have_text("No resources match your search.")
    uncheck "Meals"
    expect(page).to have_css("article h4", text: "Beta clinic")

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 800, deviceScaleFactor: 1, mobile: true)
    within("[role='search']") do
      expect(page).to have_field("Search resources", with: "clinic")
    end
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "1 resource included")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "searches and applies draft filters from the mobile toolbar" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit_builder

    title = find("h1", text: "Build your resource guide")
    expect(page).to have_text("Print a guide with addresses, hours, and contacts.")
    expect(title.evaluate_script("getComputedStyle(this.closest('header')).position")).to eq("static")
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(find_field("Search resources").evaluate_script("getComputedStyle(this.closest('[role=search]')).position")).to eq("sticky")
    find("button[aria-label='Filters']").click
    within("dialog") do
      check "Meals"
      find("button[aria-label='Close filters']").click
    end
    expect(page).to have_css("article h4", text: "Beta clinic")

    find("button[aria-label='Filters']").click
    within("dialog") do
      expect(page).to have_unchecked_field("Meals")
      check "Meals"
      check "Health Care"
      select "Resource name Z–A", from: "Sort order"
      click_button "Apply filters"
    end
    expect(page).to have_no_css("dialog[open]")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "2 resources included")
    expect(all("article h4").map(&:text)).to eq(["Beta clinic", "Alpha meals"])
    expect(page).to have_no_text("Gamma noticeboard")

    fill_in "Search resources", with: "clinic"
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "1 resource included")
    expect(page).to have_no_text("Alpha meals")
    fill_in "Search resources", with: "no such resource"
    expect(page).to have_text("No resources match your search.")
    expect(page).to have_button("Generate printout", disabled: true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "does not let a delayed old preview replace the latest selection" do
    visit_builder
    expect(page).to have_css("article h4", text: "Alpha meals")

    page.execute_script <<~JAVASCRIPT
      window.heldPreviewResponses = [];
      const originalFetch = window.fetch.bind(window);
      window.fetch = (input, options) => {
        const categories = new URL(input).searchParams.getAll("flyer[categories][]");
        if (categories.length === 1 && categories[0] === "#{food.id}") {
          const marker = document.createElement("div");
          marker.id = "held-preview-ready";
          marker.hidden = true;
          document.body.append(marker);
          return new Promise((resolve) => {
            window.heldPreviewResponses.push(() => resolve({
              ok: true,
              json: async () => ({categories: [{
                name: "Meals",
                resources: [{id: 9999, title: "Stale result", fields: []}]
              }]})
            }));
          });
        }
        return originalFetch(input, options);
      };
    JAVASCRIPT

    check "Meals"
    expect(page).to have_css("#held-preview-ready", visible: :all)

    check "Health Care"
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "2 resources included")

    page.execute_script("window.heldPreviewResponses.shift()()")
    page.evaluate_async_script("setTimeout(arguments[0], 50)")

    expect(page).to have_no_css("article h4", text: "Stale result")
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "2 resources included")
  end

  it "disables printing after a preview failure and recovers when retried" do
    visit_builder
    expect(page).to have_css("article h4", text: "Alpha meals")

    page.execute_script <<~JAVASCRIPT
      window.originalPreviewFetch = window.fetch.bind(window);
      window.fetch = () => Promise.reject(new Error("Temporary connection failure"));
    JAVASCRIPT

    check "Meals"
    expect(page).to have_text("We couldn't update your guide. Check your connection and try again.")
    expect(page).to have_button("Generate printout", disabled: true)
    expect(page).to have_css("[data-flyer-builder-target='previewError']", visible: true)

    page.execute_script("window.fetch = window.originalPreviewFetch")
    click_button "Try again"

    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(page).to have_button("Generate printout", disabled: false)
  end

  it "shows the retry state when the preview database is unavailable" do
    allow(CategorySearch).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished, "Private connection detail")

    visit_builder

    expect(page).to have_text("We couldn't update your guide. Check your connection and try again.")
    expect(page).to have_css("[data-flyer-builder-target='previewError']", visible: true)
    expect(page).to have_button("Generate printout", disabled: true)
    expect(page).to have_no_text("Private connection detail")
  end

  # Drives the first screen in real Chrome, so the builder's JavaScript runs. Only the
  # outside geocoder is faked. It runs inside the test's own server, so the fake
  # applies to the requests Chrome sends. The server-side rules are covered in more
  # detail in spec/requests/flyers_spec.rb. This checks the page and server work together.
  describe "the location screen" do
    let(:point) { GeoPoint.new(lat: 48.42, lng: -123.36) }

    before do
      Document.find_by!(title: "Alpha meals").update_columns(metadata: {lat: 48.43, lng: -123.36})
    end

    # Keeps a copy of the PDF as the page turns it into a link. Fetching the link
    # afterwards isn't possible, because the site's security policy blocks that, as
    # it should: the page only ever opens the PDF in a new tab.
    def capture_printout
      page.execute_script <<~JAVASCRIPT
        const createObjectURL = URL.createObjectURL.bind(URL);
        URL.createObjectURL = (blob) => {
          window.capturedPrintout = blob;
          return createObjectURL(blob);
        };
      JAVASCRIPT
    end

    # Reads the PDF the browser actually received. Whitespace is squeezed because
    # lines wrap wherever the page width falls.
    def printed_text
      data_url = page.evaluate_async_script(<<~JAVASCRIPT)
        const done = arguments[0];
        const reader = new FileReader();
        reader.onload = () => done(reader.result);
        reader.readAsDataURL(window.capturedPrintout);
      JAVASCRIPT
      pdf = data_url.split(",", 2).last.unpack1("m")
      PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n").gsub(/\s+/, " ")
    end

    def visit_location_screen
      visit new_flyer_path
      expect(page).to have_button("Skip distances")
      capture_printout
    end

    def continue_with_place(place)
      fill_in "Enter a place", with: place
      click_button "Continue"
    end

    it "asks where to measure from before showing the categories and preview" do
      visit_location_screen

      expect(page).to have_text("Where should we measure distances from?")
      expect(page).to have_button("Use my location")
      expect(page).to have_no_field("Meals", type: "checkbox")
      expect(page).to have_no_button("Generate printout")
      expect(page).to have_no_text("Choose what to include")
    end

    it "keeps the location controls out of the second screen" do
      visit_location_screen
      click_button "Skip distances"

      expect(page).to have_css("article h4", text: "Alpha meals")
      expect(page).to have_field("Meals", type: "checkbox")
      expect(page).to have_text("Print a guide with addresses, hours, and contacts.")
      expect(page).to have_no_button("Use my location")
      expect(page).to have_no_field("Enter a place")
    end

    it "prints no distances after skipping" do
      visit_location_screen
      click_button "Skip distances"
      expect(page).to have_text("Distances won't be shown")
      expect(page).to have_css("article h4", text: "Alpha meals")
      expect(page).to have_no_css("article", text: "Distance:")

      click_button "Generate printout"

      expect(page).to have_link("Open printout", href: /\Ablob:/)
      expect(printed_text).to include("Alpha meals")
      expect(printed_text).not_to include("Distance")
    end

    it "prints distances from a typed place, then uses the chosen categories" do
      # Once only: the printout reuses the coordinates from checking the place.
      expect(Geocoder).to receive(:locate).with("919 Pandora Ave, Victoria, BC").once.and_return(point)

      visit_location_screen
      continue_with_place("919 Pandora Ave")

      expect(page).to have_text("Distances from: 919 Pandora Ave.")
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km straight-line, about 17 min walk/)
      check "Meals"
      expect(page).to have_text("1 resource included")
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km straight-line, about 17 min walk/)
      click_button "Generate printout"

      expect(page).to have_link("Open printout", href: /\Ablob:/)
      expect(printed_text).to include("Distances are from 919 Pandora Ave", "Distance: 1.1 km straight-line, about 17 min walk")
    end

    it "continues when Enter is pressed in the box, without printing yet" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit_location_screen
      find_field("Enter a place").send_keys("919 Pandora Ave", :return)

      expect(page).to have_text("Distances from: 919 Pandora Ave.")
      expect(page).to have_no_link("Open printout")
      expect(page).to have_current_path(new_flyer_path)
    end

    it "stays on this screen when a place can't be found, then lets the person retry" do
      allow(Geocoder).to receive(:locate).and_return(nil)

      visit_location_screen
      continue_with_place("Central Library")

      expect(page).to have_css("[data-flyer-builder-target='placeError']", text: "We couldn't find that location")
      expect(page).to have_field("Enter a place", with: "Central Library")
      expect(page).to have_no_button("Generate printout")

      allow(Geocoder).to receive(:locate).and_return(point)
      fill_in "Enter a place", with: "919 Pandora Ave"
      expect(page).to have_no_css("[data-flyer-builder-target='placeError']")
      click_button "Continue"

      expect(page).to have_text("Distances from: 919 Pandora Ave.")
    end

    it "asks for a place when the box is empty" do
      expect(Geocoder).not_to receive(:locate)

      visit_location_screen
      click_button "Continue"

      expect(page).to have_css("[data-flyer-builder-target='placeError']", text: "Enter a street address")
      expect(page).to have_no_button("Generate printout")
    end

    it "lets the person carry on and explains missing distances when the geocoder is down" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable, "HTTP 503")

      visit_location_screen
      continue_with_place("919 Pandora Ave")

      expect(page).to have_text("We can't check 919 Pandora Ave right now")
      click_button "Generate printout"

      expect(page).to have_link("Open printout", href: /\Ablob:/)
      expect(printed_text).to include("Alpha meals", "Distances aren't shown")
      expect(printed_text).not_to include("Distance:")
    end

    # A printout made for the old location has the wrong distances. Categories aren't
    # affected, because the location only changes the printout.
    it "goes back with Change, discarding the printout and keeping the categories" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit_location_screen
      continue_with_place("919 Pandora Ave")
      check "Meals"
      expect(page).to have_text("1 resource included")
      click_button "Generate printout"
      expect(page).to have_link("Open printout", href: /\Ablob:/)

      click_button "Change"

      expect(page).to have_text("Where should we measure distances from?")
      expect(page).to have_field("Enter a place", with: "919 Pandora Ave")
      expect(page).to have_no_link("Open printout")

      click_button "Skip distances"

      expect(page).to have_checked_field("Meals")
      expect(page).to have_text("1 resource included")
      expect(page).to have_no_css("article", text: "Distance:")
      expect(page).to have_button("Generate printout", disabled: false)
    end

    it "updates the preview's distances when the location changes" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit_location_screen
      continue_with_place("919 Pandora Ave")
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km/)

      allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.41, lng: -123.36))
      click_button "Change"
      continue_with_place("535 Ellice St")

      expect(page).to have_text("Distances from: 535 Ellice St.")
      expect(page).to have_css("article", text: /Distance:\s+2\.2 km/)
    end

    # The location may be someone's home, so it must not end up in a URL.
    it "doesn't put the location in the preview's URL" do
      allow(Geocoder).to receive(:locate).and_return(point)
      visit_location_screen
      page.execute_script <<~JAVASCRIPT
        window.previewUrls = [];
        const originalFetch = window.fetch.bind(window);
        window.fetch = (input, options) => {
          window.previewUrls.push(String(input));
          return originalFetch(input, options);
        };
      JAVASCRIPT

      continue_with_place("919 Pandora Ave")
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km/)

      urls = page.evaluate_script("window.previewUrls")
      expect(urls.join).to include("/flyers/preview")
      expect(urls.join).not_to match(/48\.42|123\.36|Pandora/)
    end

    it "cancels a printout still being prepared when Change is pressed" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit_location_screen
      continue_with_place("919 Pandora Ave")
      expect(page).to have_button("Generate printout", disabled: false)

      allow(FlyerGenerator).to receive(:call).and_wrap_original do |generate, **options|
        sleep 1
        generate.call(**options)
      end
      printout = window_opened_by { click_button "Generate printout" }
      expect(page).to have_button("Preparing printout…", disabled: true)
      click_button "Change"
      click_button "Skip distances"

      expect(page).to have_button("Generate printout", disabled: false)
      # Long enough for the slow reply to have arrived if it hadn't been cancelled.
      page.evaluate_async_script("setTimeout(arguments[0], 1500)")
      expect(page).to have_no_link("Open printout")
      expect(page.windows).not_to include(printout)
    end

    # Uses Chrome's real location API and permission system. Chrome's developer tools
    # protocol sets the answers a person or device would give, since a test can't click
    # the browser's own permission prompt. The prompt itself isn't covered here.
    context "with Use my location" do
      def set_location_permission(setting)
        page.driver.browser.execute_cdp("Browser.setPermission",
          permission: {name: "geolocation"}, setting: setting, origin: page.server_url)
      end

      def set_device_position(latitude:, longitude:, accuracy: 50)
        page.driver.browser.execute_cdp("Emulation.setGeolocationOverride",
          latitude: latitude, longitude: longitude, accuracy: accuracy)
      end

      after do
        page.driver.browser.execute_cdp("Emulation.clearGeolocationOverride")
        page.driver.browser.execute_cdp("Browser.resetPermissions")
      end

      it "moves on and prints distances, without printing the coordinates" do
        expect(Geocoder).not_to receive(:locate)
        visit_location_screen
        set_location_permission("granted")
        set_device_position(latitude: 48.4201, longitude: -123.3602)

        click_button "Use my location"

        expect(page).to have_text("Distances from your location (accurate to about 50 m).")
        expect(page).to have_css("article", text: /Distance:\s+1\.1 km straight-line, about 17 min walk/)
        expect(find("[data-flyer-builder-target='lat']", visible: :all).value).to eq("48.420")
        expect(find("[data-flyer-builder-target='lng']", visible: :all).value).to eq("-123.360")

        click_button "Generate printout"
        expect(page).to have_link("Open printout", href: /\Ablob:/)
        expect(printed_text).to include("Distances are from your location", "Distance: 1.1 km")
        expect(printed_text).not_to include("48.42", "123.36")
      end

      it "warns on the second screen when the device's location is rough" do
        visit_location_screen
        set_location_permission("granted")
        set_device_position(latitude: 48.42, longitude: -123.36, accuracy: 3000)

        click_button "Use my location"

        expect(page).to have_text("may be off by about 3 km")
        expect(page).to have_button("Change")
      end

      it "stays on this screen and offers typing a place when location access is turned off" do
        allow(Geocoder).to receive(:locate).and_return(point)
        visit_location_screen
        set_location_permission("denied")

        click_button "Use my location"

        expect(page).to have_css("[data-flyer-builder-target='locationStatus']", text: "Location access is turned off")
        expect(find("[data-flyer-builder-target='lat']", visible: :all).value).to eq("")
        expect(page).to have_no_button("Generate printout")

        continue_with_place("919 Pandora Ave")
        expect(page).to have_text("Distances from: 919 Pandora Ave.")
      end

      it "replaces a typed place, and is replaced by one after using Change" do
        allow(Geocoder).to receive(:locate).and_return(point)
        visit_location_screen
        set_location_permission("granted")
        set_device_position(latitude: 48.42, longitude: -123.36)

        continue_with_place("919 Pandora Ave")
        expect(page).to have_text("Distances from: 919 Pandora Ave.")
        click_button "Change"
        click_button "Use my location"

        expect(page).to have_text("Distances from your location")
        expect(find_field("Enter a place", visible: :all).value).to eq("")

        click_button "Change"
        continue_with_place("535 Ellice St")

        expect(page).to have_text("Distances from: 535 Ellice St.")
        expect(find("[data-flyer-builder-target='lat']", visible: :all).value).to eq("48.42")
      end
    end
  end

  it "opens an old HTML preview link in the live builder with its filters" do
    visit preview_flyers_path(flyer: {categories: [food.id.to_s]})

    expect(page).to have_current_path(new_flyer_path, ignore_query: true)
    click_button "Skip distances"
    expect(page).to have_checked_field("Meals")
    expect(page).to have_no_checked_field("Health Care")
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(page).to have_no_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "1 resource included")
  end
end
