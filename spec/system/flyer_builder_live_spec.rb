require "rails_helper"

RSpec.describe "Live resource guide builder", type: :system do
  before do
    driven_by(:selenium, using: :headless_chrome) do |options|
      options.add_argument("--no-sandbox")
      options.add_argument("--disable-dev-shm-usage")
    end

    allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
    source = Source.create!(name: "Local", source_type: "api")
    source.documents.create!(title: "Alpha meals", content: "Meals", metadata: {resource_categories: ["food"]})
    source.documents.create!(title: "Beta clinic", content: "Clinic", metadata: {resource_categories: ["health"]})
    source.documents.create!(title: "Gamma noticeboard", content: "Noticeboard", metadata: {})
  end

  it "updates cards and print availability when categories are selected and cleared" do
    visit new_flyer_path

    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_text("All available resources · 3 resources · 3 cards")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Food"
    expect(page).to have_css("article h4", text: "Alpha meals")
    expect(page).to have_no_css("article h4", text: "Beta clinic")
    expect(page).to have_no_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_text("1 resource · 1 card")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Health"
    expect(page).to have_css("article h4", text: "Beta clinic")
    expect(page).to have_text("2 resources · 2 cards")

    uncheck "Food"
    uncheck "Health"
    expect(page).to have_css("article h4", text: "Gamma noticeboard")
    expect(page).to have_text("All available resources · 3 resources · 3 cards")
    expect(page).to have_button("Generate printout", disabled: false)

    check "Legal"
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
        if (categories.length === 1 && categories[0] === "food") {
          const marker = document.createElement("div");
          marker.id = "held-preview-ready";
          marker.hidden = true;
          document.body.append(marker);
          return new Promise((resolve) => {
            window.heldPreviewResponses.push(() => resolve({
              ok: true,
              json: async () => ({categories: [{
                name: "Food",
                resources: [{id: 9999, title: "Stale result", fields: []}]
              }]})
            }));
          });
        }
        return originalFetch(input, options);
      };
    JAVASCRIPT

    check "Food"
    expect(page).to have_css("#held-preview-ready", visible: :all)

    check "Health"
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

    check "Food"
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
    allow(ResourceCategorySearch).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished, "Private connection detail")

    visit new_flyer_path

    expect(page).to have_text("Preview unavailable")
    expect(page).to have_css("[data-flyer-builder-target='previewError']", visible: true)
    expect(page).to have_button("Generate printout", disabled: true)
    expect(page).to have_no_text("Private connection detail")
  end
end
