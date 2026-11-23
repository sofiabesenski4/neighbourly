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
    source = Source.create!(name: "Local", source_type: "csv")
    source.services.create!(name: "Alpha meals", categories: [food])
    source.services.create!(name: "Beta clinic", categories: [health])
    source.services.create!(name: "Gamma noticeboard")
  end

  # Distance checks allow any space after the label. CI doesn't build the stylesheet, so there
  # the label and value land on separate lines, and that layout isn't what they're testing.
  # Most examples here are about the second screen, so they skip the location one.
  def visit_builder
    visit new_flyer_path
    click_button "Skip distances"
  end

  # Crossing the desktop breakpoint moves the search field between the mobile toolbar and the
  # sidebar, which shifts the controls next to it. The move happens on the window's resize event,
  # a frame after the new layout applies, so wait for it before clicking or hovering.
  def emulate_mobile
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 800, deviceScaleFactor: 1, mobile: true)
    within("[data-flyer-builder-target='toolbar']") { expect(page).to have_field("Search resources") }
  end

  def clear_mobile_emulation
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    within("aside[aria-label='Resource filters']") { expect(page).to have_field("Search resources") }
  end

  it "goes directly from the questionnaire submission to its filtered preview" do
    source = Source.find_by!(name: "Local")
    source.services.create!(name: "Delta meals", categories: [food])
    source.services.create!(name: "Alpha clinic", categories: [health])
    visit root_path
    page.execute_script(<<~JS, from_questionnaire_flyers_path, food.id.to_s)
      const [path, category] = arguments;
      const form = document.createElement("form");
      form.method = "POST";
      form.action = path;
      form.dataset.turbo = "false";
      const answers = {
        "authenticity_token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        "flyer[categories][]": category,
        "flyer[query]": "Alpha"
      };
      for (const [name, value] of Object.entries(answers)) {
        const field = document.createElement("input");
        field.type = "hidden";
        field.name = name;
        field.value = value;
        form.append(field);
      }
      document.body.append(form);
      form.requestSubmit();
    JS

    expect(page).to have_current_path(from_questionnaire_flyers_path, ignore_query: false)
    expect(page).to have_no_button("Skip distances")
    expect(page).to have_field("Search resources", with: "Alpha")
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_css("article h4", count: 1)
    expect(page).to have_checked_field("Include Alpha meals in printout")
  end

  def open_alpha_details
    find("article", text: "Alpha meals").find("summary", text: "See details").click
  end

  # Capture the PDF blob before the page opens it, so assertions read the actual
  # generated document without fetching a blob URL through the site's CSP.
  def capture_printout
    page.execute_script <<~JAVASCRIPT
      const createObjectURL = URL.createObjectURL.bind(URL);
      URL.createObjectURL = (blob) => {
        window.capturedPrintout = blob;
        return createObjectURL(blob);
      };
    JAVASCRIPT
  end

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

  it "unchecks all copies of a resource, keeps its cards visible, and excludes it when printing" do
    resource = Service.find_by!(name: "Alpha meals")
    resource.categories << health
    visit_builder
    expect(page).to have_css("article h4", text: "Alpha meals", count: 2)

    all(:checkbox, "Include Alpha meals in printout").first.uncheck

    expect(page).to have_css("article h4", text: "Alpha meals", count: 2)
    expect(page).to have_no_checked_field("Include Alpha meals in printout")
    expect(page).to have_css("#flyer-preview-heading", exact_text: "2 resources included")
    capture_printout
    click_button "Generate printout"
    expect(page).to have_link("Open printout")
    expect(printed_text).to include("Beta clinic", "Gamma noticeboard")
    expect(printed_text).not_to include("Alpha meals")
  end

  it "keeps checkbox choices across category and search changes and scopes bulk actions to matching resources" do
    Service.find_by!(name: "Alpha meals").categories << health
    visit_builder

    expect(page).to have_checked_field("Include Alpha meals in printout")
    click_button "Clear selection"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "0 resources included")
    check "Include Alpha meals in printout", match: :first
    expect(all(:checkbox, "Include Alpha meals in printout").all?(&:checked?)).to be true
    check "Health Care"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "1 resource included")
    expect(page).to have_unchecked_field("Include Beta clinic in printout")
    fill_in "Search resources", with: "Beta"
    expect(page).to have_no_field("Include Alpha meals in printout")
    click_button "Select all"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "1 resource included")
    fill_in "Search resources", with: ""
    expect(page).to have_css("#flyer-preview-heading", exact_text: "2 resources included")
    uncheck "Health Care"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "2 resources included")
    expect(page).to have_unchecked_field("Include Gamma noticeboard in printout")
  end

  it "lets an admin reselect a resource and re-enable printing after deselecting all matches" do
    admin = User.create!(email: "printout-admin@example.com", password: "password123", admin: true)
    login_as(admin, scope: :user)
    visit_builder
    check "Meals"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "1 resource included")
    click_button "Clear selection"

    expect(page).to have_css("#flyer-preview-heading", exact_text: "0 resources included")
    expect(page).to have_button("Generate printout", disabled: true)
    check "Include Alpha meals in printout"

    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_css("#flyer-preview-heading", exact_text: "1 resource included")
    expect(page).to have_button("Generate printout", disabled: false)
    expect(page).to have_checked_field("Include Alpha meals in printout")
  end

  it "prints only the chosen resource after deselecting all on mobile" do
    page.current_window.resize_to(320, 740)
    visit_builder
    expect(page).to have_css("#flyer-preview-heading", exact_text: "3 resources included")
    click_button "Clear selection"
    expect(page).to have_button("Generate printout", disabled: true)
    expect(page).to have_css("article", count: 3)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be true
    selection = find(:checkbox, "Include Beta clinic in printout")
    expect(selection.find(:xpath, "..").evaluate_script("this.getBoundingClientRect().width")).to be >= 44
    expect(selection.find(:xpath, "..").evaluate_script("this.getBoundingClientRect().height")).to be >= 44
    selection.send_keys(:space)
    expect(selection).to be_checked
    expect(page.evaluate_script("document.activeElement.getAttribute('aria-label')")).to eq("Include Beta clinic in printout")
    capture_printout
    click_button "Generate printout"
    expect(page).to have_link("Open printout")
    expect(printed_text).to include("Beta clinic")
    expect(printed_text).not_to include("Alpha meals", "Gamma noticeboard")
    click_button "Select all"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "3 resources included")
    expect(page).to have_no_link("Open printout")
    expect(page).to have_button("Generate printout", disabled: false)
  ensure
    page.current_window.resize_to(1280, 900)
  end

  it "shows the default print settings and lets people change the available controls" do
    visit_builder
    expect(page).to have_no_field("Text size")

    settings = find('summary[aria-label="Print settings"]')
    expect(settings).to have_css("svg[aria-hidden='true']")
    expect(settings.text).to be_empty
    expect(settings.evaluate_script(<<~JS)).to be(true)
      this.getBoundingClientRect().left >=
        this.closest("details").previousElementSibling.getBoundingClientRect().right
    JS
    settings.click

    within_fieldset("Include map") do
      expect(page).to have_checked_field("Yes")
      choose "No"
      expect(page).to have_checked_field("No")
    end
    within_fieldset("Colour map") do
      expect(page).to have_checked_field("No", disabled: true)
    end
    within_fieldset("Include map") { choose "Yes" }
    within_fieldset("Colour map") do
      expect(page).to have_checked_field("No")
      choose "Yes"
      expect(page).to have_checked_field("Yes")
    end
    within_fieldset("Colour resource cards") do
      expect(page).to have_checked_field("No")
      choose "Yes"
      expect(page).to have_checked_field("Yes")
    end
    expect(page).to have_select("Text size", options: %w[Small Medium Large], selected: "Medium")
    expect(page).to have_no_field("Notes")

    settings.click
    expect(page).to have_no_field("Text size")
    settings.click
    expect(page).to have_field("Text size")
    find("#flyer-preview-heading").click
    expect(page).to have_no_field("Text size")
  end

  it "shows resource detail filters between Categories and Sort and applies them to the preview" do
    Service.find_by!(name: "Alpha meals").update!(
      additional_details: {"age range" => {"min" => 18}, "eligibility" => "Local residents"}
    )
    visit_builder
    open_alpha_details
    expect(page).to have_css("article dt", text: "Services:")
    expect(page).to have_css("article dt", text: "Ages served:")
    expect(page).to have_css("article dt", text: "Eligibility:")
    advanced = find('summary[title="Advanced filtering"]')
    expect(advanced).to have_css("svg[aria-hidden='true']")
    expect(advanced.find(:xpath, "../preceding-sibling::*[1]")).to have_text("Categories")
    expect(advanced.find(:xpath, "../following-sibling::*[1]")).to have_css('summary[aria-label="Sort resources"]')
    advanced.click

    within_fieldset("Resource details") do
      ["Service", "Address", "Distance and walking time", "Phone", "Ages served and eligibility", "Notes", "Intake"].each do |label|
        expect(page).to have_checked_field(label)
      end
      uncheck "Service"
      uncheck "Ages served and eligibility"
      expect(page).to have_checked_field("Address")
    end
    expect(page).to have_no_css("article dt", text: "Services:")
    expect(page).to have_no_css("article dt", text: "Ages served:")
    expect(page).to have_no_css("article dt", text: "Eligibility:")
    expect(page).to have_css("article h4", text: "Alpha meals")

    find("#flyer-preview-heading").click
    expect(page).to have_no_field("Service")
    check "Meals"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "1 resource included")
    open_alpha_details
    expect(page).to have_no_css("article dt", text: "Services:")

    advanced.click
    within_fieldset("Resource details") do
      check "Service"
      check "Ages served and eligibility"
    end
    expect(page).to have_css("article dt", text: "Services:")
    expect(page).to have_css("article dt", text: "Ages served:")
    expect(page).to have_css("article dt", text: "Eligibility:")
  end

  it "keeps the same resource detail choices available in the mobile toolbar" do
    visit_builder
    find('summary[title="Advanced filtering"]').click
    within_fieldset("Resource details") { uncheck "Service" }

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    within('[data-flyer-builder-target="toolbar"]') do
      advanced = find('summary[title="Advanced filtering"]')
      advanced.click
      within_fieldset("Resource details") { expect(page).to have_unchecked_field("Service") }
      advanced.click
    end
    open_alpha_details
    expect(page).to have_no_css("article dt", text: "Services:")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "keeps the map and text size choices through a preview update and sends them when generating" do
    visit_builder
    find('summary[aria-label="Print settings"]').click
    within_fieldset("Include map") { choose "No" }
    select "Small", from: "Text size"
    expect(page).to have_select("Text size", selected: "Small")
    select "Large", from: "Text size"
    find('summary[aria-label="Print settings"]').click
    check "Meals"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "1 resource included")
    find('summary[aria-label="Print settings"]').click
    expect(page).to have_select("Text size", selected: "Large")
    find('summary[aria-label="Print settings"]').click

    page.execute_script(<<~JS)
      window.open = () => null;
      const request = window.fetch;
      window.fetch = (url, options) => {
        if (options.headers.Accept === "application/pdf") {
          window.submittedSettings = {
            map: options.body.get("print_settings[include_map]"),
            size: options.body.get("print_settings[text_size]"),
          };
        }
        return request(url, options);
      };
    JS
    click_button "Generate printout"
    expect(page).to have_link("Open printout")
    expect(page.evaluate_script("window.submittedSettings")).to eq({"map" => "no", "size" => "20"})
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

  it "keeps resource choices across filter changes and sends only the checked cards" do
    visit_builder
    uncheck "Include Alpha meals in printout"
    uncheck "Include Gamma noticeboard in printout"
    expect(page).to have_css("#flyer-preview-heading", exact_text: "1 resource included")

    check "Meals"
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(page).to have_unchecked_field("Include Alpha meals in printout")
    expect(page).to have_button("Generate printout", disabled: true)

    uncheck "Meals"
    expect(page).to have_checked_field("Include Beta clinic in printout")
    expect(page).to have_unchecked_field("Include Gamma noticeboard in printout")
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      window.open = () => null;
      window.fetch = (url, options) => {
        if (options.headers.Accept === "application/pdf") {
          window.printoutServiceIds = options.body.getAll("flyer[service_ids][]");
        }
        return originalFetch(url, options);
      };
    JS
    click_button "Generate printout"
    expect(page).to have_link("Open printout", href: /\Ablob:/)
    expect(page.evaluate_script("window.printoutServiceIds")).to eq([Service.find_by!(name: "Beta clinic").id.to_s])
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
    source.services.create!(name: "Bravo meals", categories: [food])
    source.services.create!(name: "Charlie meals", categories: [food])
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

  it "pins the full-height desktop panel once the introduction scrolls past" do
    source = Source.find_by!(name: "Local")
    18.times { |index| source.services.create!(name: "Extra meal #{index}", categories: [food]) }
    page.current_window.resize_to(1280, 700)
    visit_builder
    expect(page).to have_css("article h4", text: "Extra meal 17")

    panel = find("aside[aria-label='Resource filters']")
    expect(panel.evaluate_script("this.getBoundingClientRect().height")).to be_within(1).of(page.evaluate_script("window.innerHeight"))
    expect(panel.evaluate_script("this.getBoundingClientRect().top")).to be > 0
    panel.execute_script("window.scrollTo(0, window.scrollY + this.getBoundingClientRect().top + 50)")
    expect(panel.evaluate_script("this.getBoundingClientRect().top")).to be_within(1).of(0)
    expect(find("h1", text: "Build your resource guide").evaluate_script("this.getBoundingClientRect().bottom")).to be < 0
  ensure
    page.current_window.resize_to(1280, 900)
  end

  it "scrolls long category lists independently on desktop and mobile" do
    24.times { |index| Category.create!(name: "Service category #{index + 1}") }
    page.current_window.resize_to(1280, 900)
    visit_builder

    within("aside[aria-label='Resource filters']") do
      list = find("[aria-label='Category list']")
      expect(list.evaluate_script("getComputedStyle(this).overflowY")).to eq("auto")
      expect(list.evaluate_script("getComputedStyle(this).overscrollBehaviorY")).to eq("auto")
      expect(list.evaluate_script("this.scrollHeight > this.clientHeight")).to be(true)
      list.execute_script("this.scrollTop = this.scrollHeight")
      expect(list.evaluate_script("this.scrollTop")).to be > 0
      expect(page).to have_field("Service category 24")
    end

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 800, deviceScaleFactor: 1, mobile: true)
    find("button[aria-label='Filters']").click
    within("#flyer-filters") do
      list = find("[aria-label='Category list']")
      expect(list.evaluate_script("getComputedStyle(this).overflowY")).to eq("auto")
      expect(list.evaluate_script("this.scrollHeight > this.clientHeight")).to be(true)
      list_bottom = list.evaluate_script("this.getBoundingClientRect().bottom")
      footer_top = find("footer").evaluate_script("this.getBoundingClientRect().top")
      expect(footer_top - list_bottom).to be_between(0, 24)
      list.execute_script("this.scrollTop = this.scrollHeight")
      expect(list.evaluate_script("this.scrollTop")).to be > 0
      check "Service category 24"
      click_button "Apply filters"
    end
    expect(page).to have_text("No resources match the selected categories.")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
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

  it "reveals the same sort choices on desktop hover and in mobile filters" do
    page.current_window.resize_to(1280, 900)
    visit_builder
    expect(page).to have_css("article h4", count: 3)

    sort = find("summary[aria-label='Sort resources']")
    expect(page).to have_no_button("Name (Z–A)")
    sort.hover
    options = ["Category", "Name (A–Z)", "Name (Z–A)", "Distance"]
    within("[aria-labelledby='desktop-sort-heading']") do
      expect(all("button").map(&:text)).to eq(options)
      expect(page).to have_css("button[aria-pressed='true']", text: "Category")
      expect(page).to have_button("Distance", disabled: true)
    end
    click_button "Name (Z–A)"
    expect(page).to have_css("article:first-child h4", text: "Gamma noticeboard")
    expect(page).to have_css("article:nth-child(2) h4", text: "Beta clinic")
    expect(all("article h4").map(&:text)).to eq(["Gamma noticeboard", "Beta clinic", "Alpha meals"])
    sort.send_keys(:enter)
    expect(page).to have_button("Name (A–Z)")
    expect(page).to have_css("button[aria-pressed='true']", text: "Name (Z–A)")
    sort.send_keys(:escape)
    expect(page).to have_no_button("Name (A–Z)")

    emulate_mobile
    find("button[aria-label='Filters (active)']").click
    within("#flyer-filters") do
      expect(page).to have_select("Sort by", options: options, selected: "Name (Z–A)")
      expect(page).to have_css("option[value='distance'][disabled]", visible: :all)
      select "Name (A–Z)", from: "Sort by"
      click_button "Apply filters"
    end
    expect(page).to have_css("article:first-child h4", text: "Alpha meals")
    clear_mobile_emulation
    find("summary[aria-label='Sort resources']").hover
    expect(page).to have_css("button[aria-pressed='true']", text: "Name (A–Z)")
    click_button "Category"
    expect(page).to have_css("h3", text: "Health Care")
    expect(page).to have_css("h3", text: "Meals")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "searches and applies draft filters from the mobile toolbar" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 320, height: 800, deviceScaleFactor: 1, mobile: true)
    visit_builder

    title = find("h1", text: "Build your resource guide")
    expect(page).to have_text("Print a contact list with names, addresses, and ways to get in touch.")
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
      select "Name (Z–A)", from: "Sort by"
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
      Service.find_by!(name: "Alpha meals").create_address!(lat: 48.43, lng: -123.36)
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

    it "enables distance sorting on both layouts and resets it when distances are skipped" do
      allow(Geocoder).to receive(:locate).and_return(point)
      Service.find_by!(name: "Beta clinic").create_address!(lat: 48.421, lng: -123.36)
      page.current_window.resize_to(1280, 900)
      visit_location_screen
      continue_with_place("919 Pandora Ave")
      within(find("h1", text: "Build your resource guide").ancestor("header")) do
        expect(page).to have_button("Edit distances")
        expect(page).to have_button("Generate printout")
      end
      find("summary[aria-label='Sort resources']").hover
      click_button "Distance"
      expect(page).to have_css("article:nth-child(2) h4", text: "Alpha meals")
      expect(all("article h4").map(&:text)).to eq(["Beta clinic", "Alpha meals", "Gamma noticeboard"])

      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: 390, height: 800, deviceScaleFactor: 1, mobile: true)
      expect(page).to have_no_text("Guide preview")
      expect(page).to have_no_button("Edit distances")
      find("button[aria-label='Filters (active)']").click
      within("#flyer-filters") do
        expect(page).to have_select("Sort by", selected: "Distance")
        expect(page).to have_css("option[value='distance']:not([disabled])", visible: :all)
        check "Meals"
        click_button "Edit distances"
      end

      within("#flyer-distances") { click_button "Skip distances" }
      within("#flyer-filters") do
        expect(page).to have_button("Add distances")
        expect(page).to have_checked_field("Meals")
        expect(page).to have_select("Sort by", selected: "Category")
        expect(page).to have_css("option[value='distance'][disabled]", visible: :all)
        click_button "Apply filters"
      end
      expect(page).to have_text("1 resource included")
      expect(page).to have_css("h3", text: "Meals")
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end

    it "keeps the location controls out of the second screen" do
      visit_location_screen
      click_button "Skip distances"

      expect(page).to have_css("article h4", text: "Alpha meals")
      expect(page).to have_field("Meals", type: "checkbox")
      expect(page).to have_text("Print a contact list with names, addresses, and ways to get in touch.")
      expect(page).to have_no_button("Use my location")
      expect(page).to have_no_field("Enter a place")
    end

    it "prints no distances after skipping" do
      visit_location_screen
      click_button "Skip distances"
      expect(page).to have_button("Add distances")
      expect(page).to have_no_text("Distances won't be shown")
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

      expect(page).to have_button("Edit distances")
      open_alpha_details
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km straight-line, about 17 min walk/)
      check "Meals"
      expect(page).to have_text("1 resource included")
      open_alpha_details
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km straight-line, about 17 min walk/)
      find('summary[title="Advanced filtering"]').click
      within_fieldset("Resource details") { uncheck "Distance and walking time" }
      expect(page).to have_no_css("article", text: "Distance:")
      within_fieldset("Resource details") { check "Distance and walking time" }
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km straight-line, about 17 min walk/)
      check "Include extra details in printout"
      click_button "Generate printout"

      expect(page).to have_link("Open printout", href: /\Ablob:/)
      expect(printed_text).to include("Distances are from 919 Pandora Ave", "Distance: 1.1 km straight-line, about 17 min walk")
    end

    it "continues when Enter is pressed in the box, without printing yet" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit_location_screen
      find_field("Enter a place").send_keys("919 Pandora Ave", :return)

      expect(page).to have_button("Edit distances")
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

      expect(page).to have_button("Edit distances")
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
      check "Include extra details in printout"
      click_button "Generate printout"

      expect(page).to have_link("Open printout", href: /\Ablob:/)
      expect(printed_text).to include("Alpha meals", "Distances aren't shown")
      expect(printed_text).not_to include("Distance:")
    end

    it "opens distance settings, discards the printout, and keeps the categories" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit_location_screen
      continue_with_place("919 Pandora Ave")
      check "Meals"
      expect(page).to have_text("1 resource included")
      click_button "Generate printout"
      expect(page).to have_link("Open printout", href: /\Ablob:/)

      click_button "Edit distances"

      within("dialog#flyer-distances[open]") do
        expect(page).to have_text("Distances from: 919 Pandora Ave.")
        expect(page).to have_field("Enter a place", with: "919 Pandora Ave")
      end
      expect(page).to have_no_link("Open printout")

      click_button "Skip distances"

      expect(page).to have_button("Add distances")
      expect(page).to have_checked_field("Meals")
      expect(page).to have_text("1 resource included")
      expect(page).to have_no_css("article", text: "Distance:")
      expect(page).to have_button("Generate printout", disabled: false)
    end

    it "adds distances from the builder and keeps the applied place if editing is cancelled" do
      allow(Geocoder).to receive(:locate).and_return(point)

      visit_location_screen
      click_button "Skip distances"
      click_button "Add distances"
      continue_with_place("919 Pandora Ave")
      open_alpha_details
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km/)

      click_button "Edit distances"
      fill_in "Enter a place", with: "535 Ellice St"
      find_field("Enter a place").send_keys(:escape)
      expect(page).to have_no_css("dialog#flyer-distances[open]")
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km/)
      expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Edit distances")

      allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.41, lng: -123.36))
      click_button "Edit distances"
      expect(page).to have_field("Enter a place", with: "919 Pandora Ave")
      continue_with_place("535 Ellice St")

      expect(page).to have_button("Edit distances")
      open_alpha_details
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
      open_alpha_details
      expect(page).to have_css("article", text: /Distance:\s+1\.1 km/)

      urls = page.evaluate_script("window.previewUrls")
      expect(urls.join).to include("/printout/preview")
      expect(urls.join).not_to match(/48\.42|123\.36|Pandora/)
    end

    it "cancels a printout still being prepared when distance settings are opened" do
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
      click_button "Edit distances"
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

        expect(page).to have_button("Edit distances")
        open_alpha_details
        expect(page).to have_css("article", text: /Distance:\s+1\.1 km straight-line, about 17 min walk/)
        expect(find("[data-flyer-builder-target='lat']", visible: :all).value).to eq("48.420")
        expect(find("[data-flyer-builder-target='lng']", visible: :all).value).to eq("-123.360")

        check "Include extra details in printout"
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
        expect(page).to have_button("Edit distances")
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
        expect(page).to have_button("Edit distances")
      end

      it "switches between a typed place and the device position in distance settings" do
        allow(Geocoder).to receive(:locate).and_return(point)
        visit_location_screen
        set_location_permission("granted")
        set_device_position(latitude: 48.42, longitude: -123.36)

        continue_with_place("919 Pandora Ave")
        expect(page).to have_button("Edit distances")
        click_button "Edit distances"
        click_button "Use my location"

        expect(page).to have_button("Edit distances")
        expect(find_field("Enter a place", visible: :all).value).to eq("")

        click_button "Edit distances"
        expect(page).to have_text("Distances from your location")
        continue_with_place("535 Ellice St")

        expect(page).to have_button("Edit distances")
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
