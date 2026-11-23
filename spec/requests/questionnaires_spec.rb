require "rails_helper"

# Covers what the questionnaire's URL returns, and the privacy rules for every response.
# Which services an answer finds is covered in spec/models/questionnaire_spec.rb.
RSpec.describe "Questionnaires", type: :request do
  let(:source) { Source.create!(name: "Local guide", source_type: "csv") }
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:shelters) { Category.create!(name: "Shelters") }

  before do
    source.services.create!(name: "Soup kitchen", categories: [meals])
    source.services.create!(name: "Shelter", categories: [shelters])
  end

  def answer(value)
    post find_help_for_myself_path, params: {questionnaire: {answers: {categories: value}}}
  end

  def page_of(response)
    Nokogiri::HTML(response.body)
  end

  describe "GET /find-help/myself" do
    it "asks the question without signing in, offering only options that can find something" do
      get "/find-help/myself"

      expect(response).to have_http_status(:ok)
      expect(page_of(response).at_css("fieldset legend h1").text).to eq("What do you need help with?")
      expect(page_of(response).css("fieldset label").map { |label| label.text.strip }).to eq(["Food", "A place to stay"])
    end

    it "sends answers in the body of a regular POST" do
      get find_help_for_myself_path

      form = page_of(response).at_css("main form")
      expect(form["method"]).to eq("post")
      expect(form["action"]).to eq("/find-help/myself")
      expect(form["data-turbo"]).to eq("false")
    end

    it "ignores answers in the URL" do
      get find_help_for_myself_path, params: {questionnaire: {answers: {categories: ["food"]}}}

      expect(page_of(response).css("input[checked]")).to be_empty
    end

    it "still loads when there are no categories" do
      Service.destroy_all
      Category.destroy_all

      get find_help_for_myself_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /find-help/myself" do
    it "lists services for one option" do
      answer(["food"])

      expect(response.media_type).to eq("text/plain")
      expect(response.body).to eq("Soup kitchen")
    end

    it "lists services for several options" do
      answer(%w[food shelter])

      expect(response.body).to eq("Shelter\nSoup kitchen")
    end

    it "lists every service when nothing is chosen" do
      post find_help_for_myself_path

      expect(response.body).to eq("Shelter\nSoup kitchen")
    end

    it "asks again when no submitted option is known" do
      answer(["unknown"])

      expect(response).to have_http_status(:unprocessable_content)
      expect(page_of(response).at_css("[role='alert']").text).to include("We couldn't read your answer")
    end

    it "asks again for malformed input, without an error page" do
      [
        {questionnaire: "food"},
        {questionnaire: ["food"]},
        {questionnaire: {answers: "food"}},
        {questionnaire: {answers: ["food"]}},
        {questionnaire: {answers: {categories: "food"}}},
        {questionnaire: {answers: {categories: {a: "food"}}}},
        {questionnaire: {answers: {categories: [{a: "food"}]}}}
      ].each do |params|
        post find_help_for_myself_path, params: params

        expect(response).to have_http_status(:unprocessable_content), "for #{params}"
      end
    end

    it "ignores unknown questions" do
      post find_help_for_myself_path, params: {questionnaire: {answers: {unknown: ["food"]}, other: "x"}}

      expect(response).to have_http_status(:ok)
    end
  end

  describe "privacy" do
    it "tells browsers not to store any response" do
      get find_help_for_myself_path
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(page_of(response).at_css("meta[name='turbo-cache-control']")["content"]).to eq("no-cache")

      answer(["food"])
      expect(response.headers["Cache-Control"]).to eq("no-store")

      answer(["unknown"])
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "hides answers from the logs" do
      answer(["food"])

      expect(request.filtered_parameters["questionnaire"]).to eq("[FILTERED]")
    end

    it "keeps answers out of the session and cookies" do
      answer(["food"])

      expect(session.to_hash.to_s).not_to include("food")
      expect(cookies.to_hash.to_s).not_to include("food")
    end
  end

  # Counts up to the real limit, using malformed requests because they're quick.
  describe "rate limit" do
    it "keeps the answers on the page, and doesn't store the response" do
      300.times { post find_help_for_myself_path, params: {questionnaire: "x"} }
      answer(["food"])

      expect(response).to have_http_status(:too_many_requests)
      expect(page_of(response).at_css("[role='alert']").text).to include("Your answers are still here")
      expect(page_of(response).css("input[checked]").map { |box| box["value"] }).to eq(["food"])
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end
end
