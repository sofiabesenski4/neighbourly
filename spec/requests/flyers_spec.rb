require "rails_helper"
require "pdf/reader"

RSpec.describe "Flyers", type: :request do
  describe "GET /flyers/new" do
    it "shows every category without signing in" do
      get new_flyer_path

      expect(response).to have_http_status(:ok)
      Flyer.available_categories.each_value do |label|
        expect(response.body).to include(ERB::Util.html_escape(label))
      end
      expect(response.body).to include('data-controller="flyer-builder"', "Generate printout", "Your guide")
    end

    it "allows only local PDF blobs to be embedded on the builder screen" do
      get new_flyer_path

      csp = response.headers.fetch("Content-Security-Policy")
      expect(csp).to include("frame-src blob:", "object-src blob:", "script-src 'self'", "frame-ancestors 'none'")
    end

    it "preserves an explicit category selection in the form" do
      get new_flyer_path, params: {flyer: {categories: ["health"]}}

      document = Nokogiri::HTML(response.body)
      expect(document.css('input[type="checkbox"][checked]').map { |input| input["value"] }).to eq(["health"])
    end

    it "starts with no categories checked and explains the unfiltered view" do
      get new_flyer_path

      document = Nokogiri::HTML(response.body)
      expect(document.css('input[type="checkbox"][checked]')).to be_empty
      expect(response.body).to include("No selection shows all available resources.")
    end
  end

  describe "POST /flyers" do
    it "hands the selected categories to the generator" do
      expect(FlyerGenerator).to receive(:call).with(categories: ["food", "harm_reduction"]).and_return(nil)

      post flyers_path, params: {flyer: {categories: ["", "food", "harm_reduction"]}}

      expect(response).to redirect_to(new_flyer_path)
      follow_redirect!
      expect(response.body).to include("No resources matched those categories")
    end

    it "sends the PDF when the generator produces one" do
      allow(FlyerGenerator).to receive(:call).and_return("%PDF-1.4 fake")

      post flyers_path, params: {flyer: {categories: ["shelter"]}}

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to eq("%PDF-1.4 fake")
    end

    it "generates the unfiltered guide when nothing is selected" do
      expect(FlyerGenerator).to receive(:call).with(categories: []).and_return("%PDF-all")

      post flyers_path, params: {flyer: {categories: [""]}}

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("%PDF-all")
    end

    it "generates the unfiltered guide when no flyer params are sent" do
      expect(FlyerGenerator).to receive(:call).with(categories: []).and_return("%PDF-all")

      post flyers_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("%PDF-all")
    end

    it "re-renders the form when the flyer param is not a hash" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: "foo"}
      expect(response).to have_http_status(:unprocessable_content)

      post flyers_path, params: {flyer: ["x"]}
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects unknown categories" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: {categories: ["spaceships"]}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("spaceships")
    end

    it "records generation failures and gives the user a useful message" do
      error = StandardError.new("PDF renderer unavailable")
      allow(FlyerGenerator).to receive(:call).and_raise(error)
      expect(Rails.error).to receive(:report).with(error, context: {feature: "category_flyer", categories: ["food"]})

      post flyers_path, params: {flyer: {categories: ["food"]}}

      expect(response).to redirect_to(new_flyer_path)
      follow_redirect!
      expect(response.body).to include("couldn&#39;t create the flyer")
    end

    it "returns structured validation errors for the live builder's PDF request" do
      post flyers_path, params: {flyer: {categories: ["unknown"]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Categories include unknown options: unknown")
    end

    it "rejects a malformed category filter instead of broadening it to all resources" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: {categories: "food"}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Categories must be provided as a list")
    end

    it "rejects an unsupported filter key instead of printing every resource" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: {category: "food"}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Unsupported flyer filters: category")
    end

    it "returns a structured empty-result error instead of following a redirect into HTML" do
      allow(FlyerGenerator).to receive(:call).and_return(nil)

      post flyers_path, params: {flyer: {categories: ["food"]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["errors"]).to include("No resources matched those categories. Try another selection.")
    end

    it "explains when the complete guide has no available resources" do
      allow(FlyerGenerator).to receive(:call).with(categories: []).and_return(nil)

      post flyers_path, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["errors"]).to include("No resources are available to print.")
    end

    it "shows the same complete-guide message after a standard form submission" do
      allow(FlyerGenerator).to receive(:call).with(categories: []).and_return(nil)

      post flyers_path, params: {flyer: {categories: [""]}}
      expect(response).to redirect_to(new_flyer_path)
      follow_redirect!

      expect(response.body).to include("No resources are available to print.")
    end

    it "reports PDF generation failures with a safe structured message" do
      error = StandardError.new("Internal renderer details")
      allow(FlyerGenerator).to receive(:call).and_raise(error)
      expect(Rails.error).to receive(:report).with(error, context: {feature: "category_flyer", categories: ["food"]})

      post flyers_path, params: {flyer: {categories: ["food"]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["errors"]).to include("We couldn't create the flyer. Please try again.")
      expect(response.body).not_to include("Internal renderer details")
    end
  end

  describe "GET /flyers/preview" do
    before do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
      source = Source.create!(name: "Local", source_type: "api")
      source.documents.create!(title: "Community meal", content: "Community meal", metadata: {resource_categories: ["food"], notes: "Call ahead"})
      source.documents.create!(title: "Unrelated clinic", content: "Clinic", metadata: {resource_categories: ["health"]})
    end

    it "displays category-filtered cards without signing in" do
      get preview_flyers_path, params: {flyer: {categories: ["food"]}}

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Community meal", "Call ahead")
      expect(response.body).not_to include("Unrelated clinic", "Last checked", "Not provided")
    end

    it "returns the same filtered data as JSON for the front-end integration" do
      get preview_flyers_path(format: :json), params: {flyer: {categories: ["food"]}}

      expect(response).to have_http_status(:ok)
      category = response.parsed_body.fetch("categories").first
      expect(category["key"]).to eq("food")
      expect(category["resources"].map { |resource| resource["title"] }).to eq(["Community meal"])
      expect(category["resources"].first["fields"]).to include({"label" => "Notes", "value" => "Call ahead"})
    end

    it "includes a category-tagged resource without an embedding in the preview and PDF" do
      source = Source.find_by!(name: "Local")
      listing = source.documents.create!(title: "Offline listing", content: "Offline listing", metadata: {resource_categories: ["food"]})
      listing.update_column(:embedding, nil)

      get preview_flyers_path(format: :json), params: {flyer: {categories: ["food"]}}

      expect(response).to have_http_status(:ok)
      titles = response.parsed_body.fetch("categories").first.fetch("resources").map { |resource| resource.fetch("title") }
      expect(titles).to include("Offline listing")

      post flyers_path, params: {flyer: {categories: ["food"]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:ok)
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("Offline listing")
    end

    it "shows all visible resources in JSON when no filters are specified" do
      get preview_flyers_path(format: :json)

      expect(response).to have_http_status(:ok)
      resources = response.parsed_body.fetch("categories").flat_map { |category| category.fetch("resources") }
      expect(resources.map { |resource| resource["title"] }).to contain_exactly("Community meal", "Unrelated clinic")
    end

    it "restores all resources when the category selection is cleared" do
      get preview_flyers_path(format: :json), params: {flyer: {categories: [""]}}

      expect(response).to have_http_status(:ok)
      resources = response.parsed_body.fetch("categories").flat_map { |category| category.fetch("resources") }
      expect(resources.map { |resource| resource["title"] }).to contain_exactly("Community meal", "Unrelated clinic")
    end

    it "generates a complete PDF without category filters" do
      post flyers_path, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("Community meal", "Unrelated clinic")
    end

    it "rejects malformed preview filters instead of treating them as an empty selection" do
      get preview_flyers_path(format: :json), params: {flyer: {categories: "food"}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Categories must be provided as a list")
    end

    it "rejects invalid category selections in JSON" do
      get preview_flyers_path(format: :json), params: {flyer: {categories: ["unknown"]}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to be_present
    end

    it "renders a usable PDF through the existing create action" do
      post flyers_path, params: {flyer: {categories: ["food"]}}

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF-")
    end

    it "records failed category lookups without exposing the exception to the front end" do
      error = StandardError.new("Private database connection detail")
      allow(ResourceCategorySearch).to receive(:call).and_raise(error)
      expect(Rails.error).to receive(:report).with(error, context: {feature: "category_preview", categories: ["food"]})

      get preview_flyers_path(format: :json), params: {flyer: {categories: ["food"]}}

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["errors"]).to include("We couldn't load those resources. Please try again.")
      expect(response.body).not_to include("Private database connection detail")
    end
  end
end
