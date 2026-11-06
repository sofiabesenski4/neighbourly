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

  it "loads a new document from the homepage before generating a PDF" do
    visit root_path
    page.execute_script("window.flyerNavigationSentinel = true")

    click_link "Make a printable flyer"

    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page.evaluate_script("window.flyerNavigationSentinel")).to be_nil

    click_button "Generate printout"

    expect(page).to have_link("Open PDF", href: /\Ablob:/)
    expect(page).to have_css('iframe[title="Printable resource guide"][src^="blob:"]', visible: :all)
  end

  it "updates cards and print availability when categories are selected and cleared" do
    visit new_flyer_path

    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_text("All available resources · 3 resources · 3 cards")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Meals"
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(page).to have_no_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_text("1 resource · 1 card")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Health Care"
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_text("2 resources · 2 cards")

    uncheck "Meals"
    uncheck "Health Care"
    expect(page).to have_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_text("All available resources · 3 resources · 3 cards")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Legal Support"
    expect(page).to have_text("No resources match the selected categories.")
    expect(page).to have_button("Generate printout", disabled: true)
  end

  it "does not let a delayed old preview replace the latest selection" do
    visit new_flyer_path
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
    expect(page).to have_text("2 resources · 2 cards")

    page.execute_script("window.heldPreviewResponses.shift()()")
    page.evaluate_async_script("setTimeout(arguments[0], 50)")

    expect(page).to have_no_css("article h4", text: "Stale result")
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_text("2 resources · 2 cards")
  end

  it "disables printing after a preview failure and recovers when retried" do
    visit new_flyer_path
    expect(page).to have_css("article h4", text: "Alpha meals")

    page.execute_script <<~JAVASCRIPT
      window.originalPreviewFetch = window.fetch.bind(window);
      window.fetch = () => Promise.reject(new Error("Temporary connection failure"));
    JAVASCRIPT

    check "Meals"
    expect(page).to have_text("Preview unavailable")
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

    visit new_flyer_path

    expect(page).to have_text("Preview unavailable")
    expect(page).to have_css("[data-flyer-builder-target='previewError']", visible: true)
    expect(page).to have_button("Generate printout", disabled: true)
    expect(page).to have_no_text("Private connection detail")
  end

  # Drives the "Near" box in real Chrome, so the builder's JavaScript runs. Only the
  # outside geocoder is faked. It runs inside the test's own server, so the fake
  # applies to the requests Chrome sends. The server-side rules are covered in more
  # detail in spec/requests/flyers_spec.rb. This checks the page and server work together.
  describe "the Near box" do
    let(:point) { GeoPoint.new(lat: 48.42, lng: -123.36) }

    before do
      Document.find_by!(title: "Alpha meals").update_columns(metadata: {lat: 48.43, lng: -123.36})
    end

    # Keeps a copy of the PDF as the page turns it into a link. Fetching the link
    # afterwards isn't possible, because the site's security policy blocks that, as
    # it should: the page only ever shows the PDF in a frame or a new tab.
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

    it "prints distances from the location that was entered" do
      expect(Geocoder).to receive(:locate).with("919 Pandora Ave, Victoria, BC").and_return(point)

      visit new_flyer_path
      expect(page).to have_css("article h4", text: "Alpha meals")
      capture_printout
      fill_in "Near", with: "919 Pandora Ave"
      click_button "Generate printout"

      expect(page).to have_link("Open PDF", href: /\Ablob:/)
      expect(printed_text).to include("Distances are from 919 Pandora Ave", "Distance: 1.1 km, about 13 min walk")
    end

    it "generates the printout when Enter is pressed in the box" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit new_flyer_path
      expect(page).to have_button("Generate printout", disabled: false)
      find_field("Near").send_keys("919 Pandora Ave", :return)

      expect(page).to have_link("Open PDF", href: /\Ablob:/)
      expect(page).to have_current_path(new_flyer_path)
    end

    it "shows what to try when the location can't be found, then lets the person retry" do
      allow(Geocoder).to receive(:locate).and_return(nil)

      visit new_flyer_path
      expect(page).to have_button("Generate printout", disabled: false)
      fill_in "Near", with: "Central Library"
      click_button "Generate printout"

      expect(page).to have_css("[data-flyer-builder-target='printError']", text: "We couldn't find that location")
      expect(page).to have_no_link("Open PDF")
      expect(page).to have_field("Near", with: "Central Library")
      expect(page).to have_button("Generate printout", disabled: false)

      allow(Geocoder).to receive(:locate).and_return(point)
      fill_in "Near", with: "919 Pandora Ave"
      expect(page).to have_no_css("[data-flyer-builder-target='printError']")
      click_button "Generate printout"

      expect(page).to have_link("Open PDF", href: /\Ablob:/)
    end

    it "explains missing distances on the printout when the geocoder is down" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable, "HTTP 503")

      visit new_flyer_path
      expect(page).to have_button("Generate printout", disabled: false)
      capture_printout
      fill_in "Near", with: "919 Pandora Ave"
      click_button "Generate printout"

      expect(page).to have_link("Open PDF", href: /\Ablob:/)
      expect(printed_text).to include("Alpha meals", "Distances aren't shown")
      expect(printed_text).not_to include("Distance:")
    end

    # A printout made for the old location has the wrong distances. The preview isn't
    # affected, because the location only changes the printout.
    it "discards a finished printout when the location changes, keeping the preview" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit new_flyer_path
      expect(page).to have_css("article h4", text: "Alpha meals")
      fill_in "Near", with: "919 Pandora Ave"
      click_button "Generate printout"
      expect(page).to have_link("Open PDF", href: /\Ablob:/)

      find_field("Near").send_keys(" West")

      expect(page).to have_no_link("Open PDF")
      expect(page).to have_no_css('iframe[title="Printable resource guide"]', visible: :all)
      expect(page).to have_css("article h4", text: "Alpha meals")
      expect(page).to have_text("Live preview")
      expect(page).to have_button("Generate printout", disabled: false)
    end

    it "cancels a printout still being prepared when the location changes" do
      allow(Geocoder).to receive(:locate) do
        sleep 1
        point
      end

      visit new_flyer_path
      expect(page).to have_button("Generate printout", disabled: false)
      fill_in "Near", with: "919 Pandora Ave"
      click_button "Generate printout"
      expect(page).to have_button("Preparing printout…", disabled: true)

      find_field("Near").send_keys(" West")

      expect(page).to have_button("Generate printout", disabled: false)
      # Long enough for the slow reply to have arrived if it hadn't been cancelled.
      page.evaluate_async_script("setTimeout(arguments[0], 1500)")
      expect(page).to have_no_link("Open PDF")
    end
  end

  it "opens an old HTML preview link in the live builder with its filters" do
    visit preview_flyers_path(flyer: {categories: [food.id.to_s]})

    expect(page).to have_current_path(new_flyer_path, ignore_query: true)
    expect(page).to have_checked_field("Meals")
    expect(page).to have_no_checked_field("Health Care")
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(page).to have_no_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_text("1 resource · 1 card")
  end
end
