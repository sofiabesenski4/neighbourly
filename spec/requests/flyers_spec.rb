require "rails_helper"

RSpec.describe "Flyers", type: :request do
  describe "GET /flyers/new" do
    it "shows every category without signing in" do
      get new_flyer_path

      expect(response).to have_http_status(:ok)
      Flyer.available_categories.each_value do |label|
        expect(response.body).to include(ERB::Util.html_escape(label))
      end
    end
  end

  describe "POST /flyers" do
    it "hands the selected categories to the generator" do
      expect(FlyerGenerator).to receive(:call).with(categories: ["food", "harm_reduction"]).and_return(nil)

      post flyers_path, params: {flyer: {categories: ["", "food", "harm_reduction"]}}

      expect(response).to redirect_to(new_flyer_path)
      follow_redirect!
      expect(response.body).to include("Flyer generation is coming soon")
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
  end
end
