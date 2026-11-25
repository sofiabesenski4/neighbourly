require "rails_helper"

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

  it "keeps parent and descendant selections in sync on desktop and mobile" do
    parent = Category.create!(name: "Food and meals")
    food.update!(parent: parent)
    Category.create!(name: "Food Banks", parent: parent)
    Category.create!(name: "Community kitchens", parent: food)
    visit new_flyer_path(flyer: {categories: [parent.id.to_s]})

    within("aside[aria-label='Resource filters']") do
      expect(page).to have_checked_field("Meals", exact: true)
      expect(page).to have_checked_field("Community kitchens")
      uncheck "Community kitchens"
      expect(page).to have_unchecked_field("Meals", exact: true)
      expect(page).to have_unchecked_field("Food and meals")
      expect(page).to have_checked_field("Food Banks")

      check "Food and meals"
      expect(page).to have_checked_field("Community kitchens")
      uncheck "Food and meals"
      expect(page).to have_unchecked_field("Food Banks")
      expect(page).to have_unchecked_field("Community kitchens")
    end

    emulate_mobile
    find("button[aria-label='Filters']").click
    within("#flyer-filters") do
      check "Food and meals"
      expect(page).to have_checked_field("Community kitchens")
      uncheck "Food and meals"
      expect(page).to have_unchecked_field("Food Banks")
      expect(page).to have_unchecked_field("Meals", exact: true)
      expect(page).to have_unchecked_field("Community kitchens")
      check "Food and meals"
      click_button "Apply filters"
    end
    clear_mobile_emulation
    within("aside[aria-label='Resource filters']") do
      expect(page).to have_checked_field("Food and meals")
      expect(page).to have_checked_field("Meals", exact: true)
      expect(page).to have_checked_field("Community kitchens")
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "goes directly from the questionnaire submission to its filtered preview" do
    source = Source.find_by!(name: "Local")
    Service.find_by!(name: "Alpha meals").create_address!(lat: 48.43, lng: -123.36)
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
        "flyer[query]": "Alpha",
        "flyer[lat]": "48.42",
        "flyer[lng]": "-123.36",
        "flyer[sort]": "distance"
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
    expect(page).to have_no_field("Enter a place")
    expect(page).to have_no_css("[data-flyer-builder-target='locationSummaryRow']", visible: :all)
    expect(page).to have_field("Search resources", with: "Alpha")
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_css("article h4", count: 1)
    within("article", text: "Alpha meals") do
      expect(page).to have_checked_field("Include")
      find("summary", text: "See details").click
      expect(page).to have_text(/Distance:\s*1\.1 km/)
    end

    emulate_mobile
    find("button[aria-label='Filters (active)']").click
    expect(page).to have_select("Sort by", selected: "Distance")
  ensure
    clear_mobile_emulation
  end

  it "narrows the guide to chosen organizations on desktop and in the mobile filters" do
    organization = Organization.create!(name: "Our Place Society")
    Service.find_by!(name: "Alpha meals").update!(organization: organization)
    visit new_flyer_path
    expect(page).to have_css("article h4", count: 3)

    find("summary", text: "Organizations").click
    check "Our Place Society"
    expect(page).to have_css("article h4", count: 1)
    expect(page).to have_css("article h4", text: "Alpha meals")

    emulate_mobile
    find("button[aria-label='Filters (active)']").click
    within("#flyer-filters") do
      expect(page).to have_checked_field("Our Place Society")
      uncheck "Our Place Society"
      click_button "Apply filters"
    end
    expect(page).to have_css("article h4", count: 3)
  ensure
    clear_mobile_emulation if organization
  end

  it "opens the generated PDF in a new tab with one click" do
    visit new_flyer_path
    expect(page).to have_button("Generate printout", disabled: false)

    printout = window_opened_by { click_button "Generate printout" }
    expect(page).to have_link("Open printout", href: /\Ablob:/)
    pdf_url = find_link("Open printout")[:href]
    within_window(printout) { expect(page).to have_current_path(pdf_url, url: true) }
  ensure
    printout&.close
  end

  it "keeps resource choices across filter changes and sends only the checked cards" do
    visit new_flyer_path
    find("article", text: "Alpha meals").uncheck("Include")
    find("article", text: "Gamma noticeboard").uncheck("Include")
    expect(page).to have_css("#flyer-preview-heading", exact_text: "1 resource included")

    check "Meals"
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(find("article", text: "Alpha meals")).to have_unchecked_field("Include")
    expect(page).to have_button("Generate printout", disabled: true)

    uncheck "Meals"
    expect(find("article", text: "Beta clinic")).to have_checked_field("Include")
    expect(find("article", text: "Gamma noticeboard")).to have_unchecked_field("Include")
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
    visit new_flyer_path

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
    visit new_flyer_path

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
    visit new_flyer_path
    expect(page).to have_css("article h4", text: "Extra meal 17")

    panel = find("aside[aria-label='Resource filters']")
    expect(panel.evaluate_script("this.getBoundingClientRect().height")).to be_within(1).of(page.evaluate_script("window.innerHeight"))
    expect(panel.evaluate_script("this.getBoundingClientRect().top")).to be > 0
    panel.execute_script("window.scrollTo(0, window.scrollY + this.getBoundingClientRect().top + 50)")
    expect(panel.evaluate_script("this.getBoundingClientRect().top")).to be_within(1).of(0)
    expect(find("h1", text: "Choose how to build your printout").evaluate_script("this.getBoundingClientRect().bottom")).to be < 0
  ensure
    page.current_window.resize_to(1280, 900)
  end

  it "scrolls long category lists independently on desktop and mobile" do
    24.times { |index| Category.create!(name: "Service category #{index + 1}") }
    page.current_window.resize_to(1280, 900)
    visit new_flyer_path

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
    visit new_flyer_path
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
    visit new_flyer_path
    expect(page).to have_css("article h4", count: 3)

    sort = find("summary[aria-label='Sort resources']")
    expect(page).to have_no_button("Name (Z–A)")
    sort.hover
    options = ["Category", "Name (A–Z)", "Name (Z–A)"]
    within("[aria-labelledby='desktop-sort-heading']") do
      expect(all("button").map(&:text)).to eq(options)
      expect(page).to have_css("button[aria-pressed='true']", text: "Category")
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
    visit new_flyer_path

    title = find("h1", text: "Choose how to build your printout")
    expect(page).to have_css("nav[aria-label='Printout view']")
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
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "2 resources included")

    page.execute_script("window.heldPreviewResponses.shift()()")
    page.evaluate_async_script("setTimeout(arguments[0], 50)")

    expect(page).to have_no_css("article h4", text: "Stale result")
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "2 resources included")
  end

  it "disables printing after a preview failure and recovers when retried" do
    visit new_flyer_path
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

    visit new_flyer_path

    expect(page).to have_text("We couldn't update your guide. Check your connection and try again.")
    expect(page).to have_css("[data-flyer-builder-target='previewError']", visible: true)
    expect(page).to have_button("Generate printout", disabled: true)
    expect(page).to have_no_text("Private connection detail")
  end

  it "opens an old HTML preview link in the live builder with its filters" do
    visit preview_flyers_path(flyer: {categories: [food.id.to_s]})

    expect(page).to have_current_path(new_flyer_path, ignore_query: true)
    expect(page).to have_checked_field("Meals")
    expect(page).to have_no_checked_field("Health Care")
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(page).to have_no_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_css("h2#flyer-preview-heading", exact_text: "1 resource included")
  end
end
