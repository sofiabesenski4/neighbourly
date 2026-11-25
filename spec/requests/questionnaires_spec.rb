require "rails_helper"
require "support/age_question"
require "support/two_question_questionnaire"

# Covers what the questionnaire's URL returns, and the privacy rules for every response.
# Which services an answer finds is covered in spec/models/questionnaire_spec.rb.
RSpec.describe "Questionnaires", type: :request do
  include AgeQuestion
  include TwoQuestionQuestionnaire

  let(:source) { Source.create!(name: "Local guide", source_type: "csv") }
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:shelters) { Category.create!(name: "Shelters") }

  before do
    source.services.create!(name: "Soup kitchen", categories: [meals])
    source.services.create!(name: "Shelter", categories: [shelters])
  end

  # Answers the first question from the last one, so that the response is the results.
  def answer(value)
    post find_help_for_myself_path, params: {questionnaire: {step: "location", answers: {categories: value}}}
  end

  def page_of(response)
    Nokogiri::HTML(response.body)
  end

  def result_names
    page_of(response).css("main article h3").map(&:text)
  end

  describe "GET /find-help/myself" do
    it "asks the question without signing in, offering only options that can find something" do
      get "/find-help/myself"

      expect(response).to have_http_status(:ok)
      expect(page_of(response).at_css("fieldset legend h1").text).to eq("What do you need help with?")
      groups = page_of(response).css("fieldset [role=group]")
      expect(groups.map { |group| group["aria-label"] }).to eq(["Food and meals", "Housing Services"])
      expect(groups[0].css("label").map { |label| label.text.strip }).to eq(["Food and meals", "Meals"])
      expect(groups[1].css("label").map { |label| label.text.strip }).to eq(["Housing Services", "Shelters"])
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

      expect(response.media_type).to eq("text/html")
      expect(result_names).to eq(["Soup kitchen"])
      document = page_of(response)
      expect(document.at_css('nav[aria-label="Printout view"] [aria-current="page"]').text).to include("Answer a few questions")
      expect(document.at_css('nav[aria-label="Printout view"] a[href="/printout"]').text).to include("Build my own guide")
      expect(document.at_css("aside[aria-label='Resource filters']")).to be_nil
      expect(document.at_css("dialog#flyer-filters")).to be_nil
      expect(document.at_css("input[type='checkbox'][name='flyer[service_ids][]'][checked]")).to be_present
      expect(document.at_css("input[type='checkbox'][name='flyer[detail_level]']")).to be_present
      expect(document.at_css("button[type='submit'][data-flyer-builder-target='generate']").text).to include("Generate printout")
    end

    it "lists services for several options" do
      answer(%w[food shelter])

      expect(result_names).to eq(["Shelter", "Soup kitchen"])
    end

    it "lists every service when nothing is chosen" do
      post find_help_for_myself_path, params: {questionnaire: {step: "location"}}

      expect(result_names).to eq(["Shelter", "Soup kitchen"])
    end

    it "disables printing when there are no matching resources" do
      Service.find_by!(name: "Soup kitchen").destroy!
      answer(["food"])

      expect(result_names).to be_empty
      expect(response.body).to include("No resources match your answers.")
      expect(page_of(response).at_css("button[data-flyer-builder-target='generate'][disabled]")).to be_present
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
        {questionnaire: {answers: {categories: [{a: "food"}]}}},
        {questionnaire: {answers: {location: "food"}}},
        {questionnaire: {answers: {location: ["food"]}}},
        {questionnaire: {answers: {location: {near: ["food"]}}}},
        {questionnaire: {answers: {location: {near: {a: "food"}}}}}
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
      expect(page_of(response).at_css("meta[name='turbo-cache-control']")["content"]).to eq("no-cache")

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
      post find_help_for_myself_path, params: {questionnaire: {step: "categories", answers: {categories: ["food"]}}}

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

      expect(result_names).to eq(["Our Place meals"])
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

  describe "the location question" do
    before do
      Service.destroy_all
      source.services.create!(name: "Far kitchen", categories: [meals], address_attributes: {lat: 48.50, lng: -123.36})
      source.services.create!(name: "Near kitchen", categories: [meals], address_attributes: {lat: 48.421, lng: -123.36})
      allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.42, lng: -123.36))
    end

    def submit_place(near, move: "next", **fields)
      post find_help_for_myself_path, params: {
        questionnaire: {step: "location", move: move, answers: {categories: ["food"], location: {near: near, **fields}}}
      }
    end

    it "lists the closest services first" do
      submit_place("919 Pandora Ave")

      expect(result_names).to eq(["Near kitchen", "Far kitchen"])
    end

    it "asks again when the place isn't found, with what was typed and the other answers" do
      allow(Geocoder).to receive(:locate).and_return(nil)
      submit_place("Central Library")

      expect(response).to have_http_status(:unprocessable_content)
      expect(page_of(response).at_css("[role='alert']").text).to include("We couldn't find that place")
      expect(page_of(response).at_css("title").text).to eq("Problem - Question 2 of 2 - Find help")
      field = page_of(response).at_css("input[type='text']")
      expect(field["value"]).to eq("Central Library")
      expect(field["aria-describedby"]).to include("question-message")
      expect(page_of(response).at_css("input[name='questionnaire[answers][categories][]']")["value"]).to eq("food")
    end

    it "says when a place is too long" do
      submit_place("a" * 201)

      expect(response).to have_http_status(:unprocessable_content)
      expect(page_of(response).at_css("[role='alert']").text).to include("That's too long")
    end

    it "says so and carries on when the address service is down" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable)
      submit_place("919 Pandora Ave")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("We can't look up places right now, so these services aren't sorted by distance.")
      expect(result_names).to eq(["Far kitchen", "Near kitchen"])
    end

    it "doesn't mention distances to someone who skipped the question" do
      submit_place("919 Pandora Ave", move: "skip")

      expect(result_names).to eq(["Far kitchen", "Near kitchen"])
    end

    it "keeps a place that has been looked up when returning to it" do
      post find_help_for_myself_path, params: {questionnaire: {step: "categories", answers: {
        location: {near: "919 Pandora Ave", checked: "919 Pandora Ave", lat: "48.42", lng: "-123.36"}
      }}}

      expect(page_of(response).at_css("input[type='text']")["value"]).to eq("919 Pandora Ave")
      hidden = page_of(response).css("input[type='hidden'][name*='[location]']").to_h { |input| [input["name"][/\w+(?=\]\z)/], input["value"]] }
      expect(hidden).to eq("device" => nil, "checked" => "919 Pandora Ave", "lat" => "48.42", "lng" => "-123.36")
    end

    it "leaves the location as a hidden field on other questions" do
      submit_place("919 Pandora Ave", move: "back")

      expect(page_of(response).at_css("h1").text).to eq("What do you need help with?")
      expect(page_of(response).at_css("input[type='hidden'][name='questionnaire[answers][location][near]']")["value"]).to eq("919 Pandora Ave")
    end

    it "hides the place from the logs, and from a report that the address service is down" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable)
      expect(Rails.error).to receive(:report).with(instance_of(Geocoder::Unavailable), context: {feature: "flyer_origin"})

      submit_place("919 Pandora Ave")

      expect(request.filtered_parameters["questionnaire"]).to eq("[FILTERED]")
    end

    it "offers the device's location as something JavaScript has to reveal" do
      post find_help_for_myself_path, params: {questionnaire: {step: "categories"}}

      offer = page_of(response).at_css("[data-device-location-target='offer']")
      expect(offer["hidden"]).not_to be_nil
      expect(offer.at_css("button")["type"]).to eq("button")
      expect(offer.text).to include("such as Google's or Apple's")
    end

    it "sorts by distance from the device's location" do
      submit_place("", device: "1", checked: "", lat: "48.42", lng: "-123.36")

      expect(result_names).to eq(["Near kitchen", "Far kitchen"])
      expect(Geocoder).not_to have_received(:locate)
    end

    it "shows that the device's location is in use when returning to the question" do
      post find_help_for_myself_path, params: {questionnaire: {step: "categories", answers: {
        location: {device: "1", lat: "48.42", lng: "-123.36"}
      }}}

      status = page_of(response).at_css("[role='status']")
      expect(status.text).to eq("Using your location.")
      expect(status["hidden"]).to be_nil
      expect(page_of(response).at_css("input[name='questionnaire[answers][location][device]']")["value"]).to eq("1")
      expect(page_of(response).at_css("input[name='questionnaire[answers][location][lat]']")["value"]).to eq("48.42")
    end

    it "asks again when the device's location can't be read" do
      submit_place("", device: "1", lat: "north", lng: "-123.36")

      expect(response).to have_http_status(:unprocessable_content)
      expect(page_of(response).at_css("[role='alert']").text).to include("We couldn't read your device's location")
    end

    it "stops looking places up after 60 in an hour, and carries on without distances" do
      60.times { submit_place("919 Pandora Ave") }
      expect(result_names).to eq(["Near kitchen", "Far kitchen"])

      submit_place("919 Pandora Ave")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("We can't look up places right now")
      expect(Geocoder).to have_received(:locate).exactly(60).times
    end

    it "doesn't count requests that look nothing up" do
      60.times { submit_place("919 Pandora Ave", move: "skip") }
      submit_place("919 Pandora Ave")

      expect(result_names).to eq(["Near kitchen", "Far kitchen"])
    end
  end

  # Added by config and a filter alone. Which services it hides is in the model spec.
  it "asks and answers a question about a service's details with no view of its own" do
    use_age_question
    source.services.create!(name: "Adult kitchen", categories: [meals], additional_details: {"ages" => "19+"})

    post find_help_for_myself_path, params: {questionnaire: {step: "location", answers: {categories: ["food"]}}}
    expect(page_of(response).at_css("#question-progress").text).to eq("Question 3 of 3")
    expect(page_of(response).at_css("h1").text).to eq("How old are you?")
    expect(page_of(response).css("fieldset label").map { |label| label.text.strip }).to eq(["Under 19", "19 or older"])

    post find_help_for_myself_path, params: {questionnaire: {step: "age", answers: {categories: ["food"], age: ["under_19"]}}}
    expect(result_names).to eq(["Soup kitchen"])
  end

  it "counts a question as a step only while a service has the details it requires" do
    use_age_question(requires: "age_range")
    get find_help_for_myself_path
    expect(page_of(response).at_css("#question-progress").text).to eq("Question 1 of 2")

    source.services.create!(name: "Adult kitchen", categories: [meals], additional_details: {"ages" => "19+"})
    get find_help_for_myself_path
    expect(page_of(response).at_css("#question-progress").text).to eq("Question 1 of 3")
  end

  # The results page isn't built yet, so this draws the button on its own, as that page will,
  # and then submits what it holds.
  describe "the change button" do
    let(:answers) { {categories: ["food"], location: {device: "1", lat: "48.42", lng: "-123.36"}} }

    let(:results) do
      questionnaire = Questionnaire.new(answers: answers.deep_stringify_keys, step: "location")
      questionnaire.move("next")
      questionnaire.results
    end

    def button_for(key)
      answer = results.answers.find { |candidate| candidate.key == key }
      Nokogiri::HTML(ApplicationController.render(partial: "questionnaires/change_answer", locals: {results: results, answer: answer}))
    end

    # Every name and value the browser would send, including the button's own.
    def press(form)
      controls = form.css("input[name^='questionnaire'], button")
      post form.at_css("form")["action"], params: URI.encode_www_form(controls.map { |control| [control["name"], control["value"]] })
    end

    it "opens its question with that answer filled in, and the others carried" do
      press(button_for("categories"))

      expect(response).to have_http_status(:ok)
      expect(page_of(response).at_css("h1").text).to eq("What do you need help with?")
      expect(page_of(response).css("input[checked]").map { |box| box["value"] }).to eq(["food"])
      expect(page_of(response).at_css("input[name='questionnaire[answers][location][lat]']")["value"]).to eq("48.42")

      press(button_for("location"))

      expect(page_of(response).at_css("h1").text).to eq("Where are you?")
      expect(page_of(response).at_css("[role='status']").text).to eq("Using your location.")
      expect(page_of(response).at_css("input[name='questionnaire[answers][categories][]']")["value"]).to eq("food")
    end

    it "sends answers in the body of a regular POST, never in the URL" do
      form = button_for("categories").at_css("form")

      expect(form["method"]).to eq("post")
      expect(form["action"]).to eq("/find-help/myself")
      expect(form["data-turbo"]).to eq("false")
      expect(form["autocomplete"]).to eq("off")
    end

    it "says which answer it changes" do
      expect(button_for("location").at_css("button").text.squish).to eq("Change your answer to: Where are you?")
    end

    it "keeps answers out of logs, the session and stored responses" do
      press(button_for("categories"))

      expect(request.filtered_parameters["questionnaire"]).to eq("[FILTERED]")
      expect(session.to_hash.to_s).not_to include("food")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "escapes what someone typed" do
      allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.42, lng: -123.36))
      answers[:location] = {near: %("><script>alert(1)</script>)}

      expect(button_for("location").css("script")).to be_empty
      expect(button_for("location").at_css("input[name$='[near]']")["value"]).to eq(%("><script>alert(1)</script>))
    end
  end
end
