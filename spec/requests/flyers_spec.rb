require "rails_helper"

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

    it "re-renders the form when nothing is selected" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: {categories: [""]}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must include at least one type of information")
    end

    it "re-renders the form when no flyer params are sent" do
      post flyers_path

      expect(response).to have_http_status(:unprocessable_content)
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
      post flyers_path, params: {flyer: {categories: []}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Categories must include at least one type of information")
    end

    it "returns a structured empty-result error instead of following a redirect into HTML" do
      allow(FlyerGenerator).to receive(:call).and_return(nil)

      post flyers_path, params: {flyer: {categories: ["food"]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["errors"]).to include("No resources matched those categories. Try another selection.")
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
