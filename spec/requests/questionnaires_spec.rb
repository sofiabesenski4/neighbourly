require "rails_helper"
require "support/two_question_questionnaire"

# Covers what the questionnaire's URL returns, and the privacy rules for every response.
# Which services an answer finds is covered in spec/models/questionnaire_spec.rb.
RSpec.describe "Questionnaires", type: :request do
  include TwoQuestionQuestionnaire

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

  # Where each button leads is covered in the model spec. This covers what the pages say.
  describe "several questions" do
    before do
      Service.destroy_all
      Category.destroy_all
      use_two_questions
    end

    def submit(step: "needs", move: "next", **answers)
      post find_help_for_myself_path, params: {questionnaire: {step: step, move: move, answers: answers}}
    end

    def buttons
      page_of(response).css("main form button").map { |button| button.text.strip }
    end

    def carried
      page_of(response).css("main form input[type='hidden'][name^='questionnaire']").map { |input| [input["name"], input["value"]] }
    end

    it "shows progress and the buttons that apply, with Next first" do
      get find_help_for_myself_path
      expect(page_of(response).at_css("title").text).to eq("Question 1 of 2 - Find help")
      expect(page_of(response).at_css("#question-progress").text).to eq("Question 1 of 2")
      expect(buttons).to eq(%w[Next Skip])

      submit(needs: ["food"])
      expect(response).to have_http_status(:ok)
      expect(page_of(response).at_css("h1").text).to eq("Who would you like to go to?")
      expect(page_of(response).at_css("#question-progress").text).to eq("Question 2 of 2")
      expect(buttons).to eq(%w[Next Back Skip])
    end

    it "carries the step and the other answers in hidden fields, but not the current one" do
      submit(step: "who", move: "back", needs: ["food"], who: ["our_place"])

      expect(carried).to contain_exactly(["questionnaire[step]", "needs"], ["questionnaire[answers][who][]", "our_place"])
      expect(page_of(response).css("input[checked]").map { |box| box["value"] }).to eq(["food"])
    end

    it "shows a radio question's answer when returning to it" do
      submit(needs: ["food"], who: ["our_place"])

      radios = page_of(response).css("input[type='radio']")
      expect(radios.map { |radio| radio["name"] }.uniq).to eq(["questionnaire[answers][who][]"])
      expect(radios.select { |radio| radio["checked"] }.map { |radio| radio["value"] }).to eq(["our_place"])
    end

    it "lists the services matching every answer after the last question" do
      submit(step: "who", needs: ["food"], who: ["our_place"])

      expect(response.body).to eq("Our Place meals")
    end

    it "starts over with a plain link that holds no answers" do
      submit(needs: ["food"])

      link = page_of(response).at_xpath("//main//a[contains(., 'Start over')]")
      expect(link["href"]).to eq("/find-help/myself")
      expect(link["data-turbo"]).to eq("false")
    end

    it "asks an unreadable question again, carrying the other answers" do
      submit(step: "who", needs: ["unknown"], who: ["our_place"])

      expect(response).to have_http_status(:unprocessable_content)
      expect(page_of(response).at_css("h1").text).to eq("What do you need?")
      expect(carried).to include(["questionnaire[answers][who][]", "our_place"])
    end

    it "copes with unknown steps and buttons" do
      [{step: "gone"}, {step: ["who"]}, {step: {a: "b"}}, {move: "sideways"}, {move: ["back"]}, {move: {a: "b"}}].each do |params|
        post find_help_for_myself_path, params: {questionnaire: params}

        expect(response).to have_http_status(:ok), "for #{params}"
      end
    end

    it "keeps answers out of stored responses and logs on every screen" do
      submit(needs: ["food"])

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(request.filtered_parameters["questionnaire"]).to eq("[FILTERED]")
      expect(session.to_hash.to_s).not_to include("food")
    end

    it "stays on the same question, with every answer, over the rate limit" do
      300.times { post find_help_for_myself_path, params: {questionnaire: "x"} }
      submit(step: "who", needs: ["food"], who: ["our_place"])

      expect(response).to have_http_status(:too_many_requests)
      expect(page_of(response).at_css("h1").text).to eq("Who would you like to go to?")
      expect(carried).to include(["questionnaire[answers][needs][]", "food"])
      expect(page_of(response).at_css("input[checked]")["value"]).to eq("our_place")
    end
  end

  it "shows no progress or Back when there is one question" do
    allow(Questionnaire).to receive(:questions_from).and_return(Questionnaire.questions_from.first(1))

    get find_help_for_myself_path

    expect(page_of(response).at_css("title").text).to eq("Find help")
    expect(page_of(response).at_css("#question-progress")).to be_nil
    expect(page_of(response).css("main form button").map(&:text)).to eq(%w[Next Skip])
  end
end
