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
    expect(page).to have_css('button[data-flyer-builder-target="generate"] svg[fill="none"][stroke="currentColor"]')
    expect(page).to have_css('iframe[title="Printable resource guide"][src^="blob:"]', visible: :all)
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
