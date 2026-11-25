require "rails_helper"
require "support/age_question"
require "support/two_question_questionnaire"

# Covers the questionnaire's rules: what the config must contain, how submitted answers are
# read, how people move between questions, and which services the answers find. The HTTP side is in
# spec/requests/questionnaires_spec.rb, and turning categories into IDs is in
# spec/models/questionnaire/category_filter_spec.rb.
RSpec.describe Questionnaire do
  include AgeQuestion
  include TwoQuestionQuestionnaire

  let(:source) { Source.create!(name: "Local guide", source_type: "csv") }
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:food_banks) { Category.create!(name: "Food Banks") }
  let!(:shelters) { Category.create!(name: "Shelters") }

  def service(name, *categories, **attributes)
    source.services.create!(name: name, categories: categories, **attributes)
  end

  def names(answers)
    described_class.new(answers: answers).services.map(&:name)
  end

  # Writes a config file containing the given YAML, and loads its questions.
  def questions_from(yaml)
    Tempfile.create(["questionnaire", ".yml"]) do |file|
      file.write(yaml)
      file.flush
      described_class.questions_from(file.path)
    end
  end

  # The real config, checked against the categories every database starts with.
  describe "config/questionnaire.yml" do
    let(:questions) { described_class.questions_from }
    let(:seeded) { YAML.safe_load_file(Rails.root.join("db/category_names.yml")) }
    let(:named) { questions.flat_map(&:all_options).flat_map(&:categories) }

    it "loads, so every question names a known type and filter" do
      expect(questions).not_to be_empty
    end

    it "gives every question its own key, and every option its own key within a question" do
      expect(questions.map(&:key).tally.values).to all(eq(1))
      questions.each { |question| expect(question.all_options.map(&:key).tally.values).to all(eq(1)) }
    end

    it "names no category that isn't seeded" do
      expect(named - seeded).to be_empty
    end

    it "puts every seeded category in an option" do
      expect(seeded - named).to be_empty
    end

    it "has a view for every type" do
      Questionnaire::Question::TYPES.each do |type|
        expect(Rails.root.join("app/views/questionnaires/_#{type}.html.erb")).to exist
      end
    end
  end

  describe ".questions_from" do
    let(:yaml) do
      <<~YAML
        questions:
          - key: needs
            title: What do you need?
            type: checkboxes
            filter: CategoryFilter
            options:
              - { key: eat, label: Something to eat, categories: [Meals] }
      YAML
    end

    it "adds an option from the config alone" do
      questions = questions_from(yaml + "      - { key: sleep, label: Somewhere to sleep, categories: [Shelters] }\n")

      expect(questions.first.options.map(&:label)).to eq(["Something to eat", "Somewhere to sleep"])
    end

    it "rejects a filter that isn't registered" do
      expect { questions_from(yaml.sub("CategoryFilter", "Kernel")) }.to raise_error(KeyError)
    end

    it "rejects a type that isn't supported" do
      expect { questions_from(yaml.sub("checkboxes", "slider")) }.to raise_error(KeyError, /slider/)
    end
  end

  # Two category questions would both set `categories`, and the second would win.
  it "rejects two questions that set the same part of the search" do
    entry = YAML.safe_load_file(described_class::CONFIG_PATH)["questions"].first
    yaml = {"questions" => [entry, entry.deep_dup.merge("key" => "more")]}.to_yaml

    expect { questions_from(yaml) }.to raise_error(ArgumentError, /categories/)
  end

  describe "#services" do
    it "finds services in any category behind the chosen option" do
      service("Soup kitchen", meals)
      service("Food bank", food_banks)
      service("Shelter", shelters)

      expect(names("categories" => ["food"])).to eq(["Food bank", "Soup kitchen"])
    end

    it "lets a subcategory narrow the search to a single part of a group" do
      service("Soup kitchen", meals)
      service("Food bank", food_banks)

      expect(names("categories" => ["meals"])).to eq(["Soup kitchen"])
      expect(names("categories" => ["food_banks"])).to eq(["Food bank"])
    end

    it "finds services matching any chosen option" do
      service("Soup kitchen", meals)
      service("Shelter", shelters)

      expect(names("categories" => %w[food shelter])).to eq(["Shelter", "Soup kitchen"])
    end

    it "lists a service in several chosen categories once" do
      service("Soup kitchen and food bank", meals, food_banks)

      expect(names("categories" => ["food"])).to eq(["Soup kitchen and food bank"])
    end

    it "finds the same services as a printout of the same categories" do
      service("Soup kitchen", meals)
      service("Food bank", food_banks)
      service("Both", meals, food_banks)
      service("Shelter", shelters)
      printout = CategorySearch.call(categories: [meals.id.to_s, food_banks.id.to_s]).flat_map(&:resources).uniq

      expect(described_class.new(answers: {"categories" => ["food"]}).services).to match_array(printout)
    end

    it "finds every visible service when nothing is chosen" do
      service("Soup kitchen", meals)
      service("Uncategorized")
      service("Closed kitchen", meals, closed: true)

      expect(names({})).to eq(["Soup kitchen", "Uncategorized"])
      expect(names("categories" => [])).to eq(["Soup kitchen", "Uncategorized"])
      expect(names("categories" => [""])).to eq(["Soup kitchen", "Uncategorized"])
    end

    it "leaves out closed services and ones a moderator removed" do
      row = source.documents.build(title: "Removed", content: "Removed")
      allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
      row.save!
      row.reports.create!(reason: "out of date", status: "valid")
      service("Removed kitchen", meals, document: row)
      service("Closed kitchen", meals, closed: true)
      service("Open kitchen", meals)

      expect(names("categories" => ["food"])).to eq(["Open kitchen"])
    end
  end

  describe "#valid?" do
    it "accepts a known option, and ignores an unknown one beside it" do
      questionnaire = described_class.new(answers: {"categories" => %w[food unknown]})

      expect(questionnaire).to be_valid
      expect(questionnaire.answer_to(questionnaire.question).options.map(&:key)).to eq(["food"])
    end

    it "ignores questions it doesn't have" do
      expect(described_class.new(answers: {"unknown" => ["food"]})).to be_valid
    end

    it "rejects an answer with no option it knows" do
      expect(described_class.new(answers: {"categories" => ["unknown"]})).not_to be_valid
    end

    # Youth Services doesn't exist here, so its option isn't offered.
    it "rejects an option that is hidden because its categories are missing" do
      expect(described_class.new(answers: {"categories" => ["youth"]})).not_to be_valid
    end

    it "rejects values that aren't a list of text" do
      ["food", {"0" => "food"}, [["food"]], [{"a" => "food"}]].each do |value|
        expect(described_class.new(answers: {"categories" => value})).not_to be_valid
      end
      expect(described_class.new(answers: "food")).not_to be_valid
    end
  end

  describe "several questions" do
    # These replace the categories created above, which use the same names.
    before do
      Category.destroy_all
      use_two_questions
    end

    def questionnaire(step: "needs", **answers)
      described_class.new(answers: answers.transform_keys(&:to_s), step: step)
    end

    def keys(questionnaire)
      questionnaire.questions.to_h { |question| [question.key, questionnaire.answer_to(question).options.map(&:key)] }
    end

    def moved(direction, **options)
      questionnaire(**options).tap { |moved| moved.move(direction) }
    end

    it "starts at the first question" do
      first = described_class.new

      expect(first.question.key).to eq("needs")
      expect(first).to be_first
      expect(first.position).to eq(1)
    end

    it "narrows the search with every answer" do
      found = questionnaire(needs: ["food"], who: ["our_place"]).services

      expect(found.map(&:name)).to eq(["Our Place meals"])
    end

    it "finds the same services whatever order the questions were answered in" do
      forward = described_class.new(answers: {"needs" => ["food"], "who" => ["our_place"]})
      backward = described_class.new(answers: {"who" => ["our_place"], "needs" => ["food"]})

      expect(forward.services).to eq(backward.services)
    end

    it "goes forward with Next, keeping answers, and finishes after the last question" do
      second = moved("next", needs: ["food"])
      expect(second.question.key).to eq("who")
      expect(second).not_to be_finished
      expect(second).not_to be_first
      expect(keys(second)).to eq("needs" => ["food"], "who" => [])

      expect(moved("next", step: "who", needs: ["food"], who: ["our_place"])).to be_finished
    end

    it "treats a missing or unknown button as Next" do
      [nil, "sideways", ["next"]].each do |direction|
        expect(moved(direction).question.key).to eq("who")
      end
    end

    it "goes back with every answer, including the current one" do
      first = moved("back", step: "who", needs: ["food"], who: ["our_place"])

      expect(first.question.key).to eq("needs")
      expect(keys(first)).to eq("needs" => ["food"], "who" => ["our_place"])
    end

    it "shows a question without moving, keeping every answer, for changing one from the results" do
      %w[needs who].each do |step|
        shown = moved("show", step: step, needs: ["food"], who: ["our_place"])

        expect(shown.question.key).to eq(step)
        expect(shown).not_to be_finished
        expect(keys(shown)).to eq("needs" => ["food"], "who" => ["our_place"])
      end
    end

    it "shows a question even if an answer can't be read, dropping that one" do
      shown = moved("show", step: "who", needs: ["unknown"], who: ["our_place"])

      expect(shown).to be_valid
      expect(shown.question.key).to eq("who")
      expect(keys(shown)).to eq("needs" => [], "who" => ["our_place"])
    end

    it "stays on the first question when going back from it" do
      expect(moved("back").question.key).to eq("needs")
    end

    it "clears only the current question with Skip" do
      second = moved("skip", needs: ["food"], who: ["our_place"])
      expect(second.question.key).to eq("who")
      expect(keys(second)).to eq("needs" => [], "who" => ["our_place"])

      done = moved("skip", step: "who", needs: ["food"], who: ["our_place"])
      expect(done).to be_finished
      expect(keys(done)).to eq("needs" => ["food"], "who" => [])
    end

    it "finds every service when every question is skipped" do
      everything = CategorySearch.call(categories: [], sort: "asc").flat_map(&:resources)

      expect(moved("skip", step: "who").services).to eq(everything)
      expect(everything.size).to eq(4)
    end

    it "asks an earlier question again when its answer can't be read" do
      again = moved("next", step: "who", needs: ["unknown"], who: ["our_place"])

      expect(again.question.key).to eq("needs")
      expect(again).not_to be_valid
      expect(again).not_to be_finished
    end

    it "lets an answer that can't be read be skipped, or left behind by going back" do
      expect(moved("skip", needs: ["unknown"])).to be_valid

      first = moved("back", step: "who", needs: ["food"], who: ["unknown"])
      expect(first).to be_valid
      expect(keys(first)).to eq("needs" => ["food"], "who" => [])
    end

    it "goes to the first question, with answers kept, when the step is unknown" do
      ["gone", ["who"], "2"].each do |step|
        first = moved("next", step: step, who: ["our_place"])

        expect(first.question.key).to eq("needs")
        expect(first).not_to be_finished
        expect(keys(first)).to include("who" => ["our_place"])
      end
    end

    it "rejects more than one answer to a radio question" do
      expect(questionnaire(who: %w[our_place the_mustard_seed])).not_to be_valid
    end
  end

  # Uses the real config, whose second question is the location. How a typed place is read is
  # in spec/models/questionnaire/location_answer_spec.rb.
  describe "the location question" do
    let(:place) { {"near" => "919 Pandora Ave"} }
    let(:located) { place.merge("checked" => "919 Pandora Ave", "lat" => "48.42", "lng" => "-123.36") }

    before do
      service("Far meals", meals, address_attributes: {lat: 48.50, lng: -123.36})
      service("Unknown meals", meals)
      service("Near meals", meals, address_attributes: {lat: 48.421, lng: -123.36})
      service("Near shelter", shelters, address_attributes: {lat: 48.42, lng: -123.36})
      allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.4200001, lng: -123.3600001))
    end

    def moved(direction, step: "location", lookup: true, **answers)
      described_class.new(answers: answers.transform_keys(&:to_s), step: step).tap { |moved| moved.move(direction, lookup: lookup) }
    end

    it "puts the closest services first and ones with no known location last" do
      expect(moved("next", categories: ["food"], location: place).services.map(&:name))
        .to eq(["Near meals", "Far meals", "Unknown meals"])
    end

    it "never hides a service" do
      expect(moved("next", location: place).services).to match_array(Service.all)
    end

    it "finds the same services in the same order whichever was answered first" do
      forward = described_class.new(answers: {"categories" => ["food"], "location" => located})
      backward = described_class.new(answers: {"location" => located, "categories" => ["food"]})

      expect(forward.services).to eq(backward.services)
    end

    it "looks the place up when going forward from it, and finishes" do
      done = moved("next", location: place)

      expect(done).to be_finished
      expect(done).not_to be_missing_distances
      expect(Geocoder).to have_received(:locate).once
    end

    it "doesn't look anything up for Back, Skip, an empty place or another question" do
      moved("back", location: place)
      moved("show", location: place)
      moved("skip", location: place)
      moved("next", location: {"near" => " "})
      moved("next", step: "categories", location: place)

      expect(Geocoder).not_to have_received(:locate)
    end

    it "doesn't repeat a lookup, until the place changes" do
      moved("next", location: located)
      expect(Geocoder).not_to have_received(:locate)

      moved("next", location: located.merge("near" => "1 Fort St"))
      expect(Geocoder).to have_received(:locate).with("1 Fort St, Victoria, BC")
    end

    it "doesn't look a place up when another answer has to be fixed first" do
      again = moved("next", categories: ["unknown"], location: place)

      expect(again.question.key).to eq("categories")
      expect(Geocoder).not_to have_received(:locate)
    end

    it "asks again when the place isn't found, keeping what was typed" do
      allow(Geocoder).to receive(:locate).and_return(nil)
      again = moved("next", location: place)

      expect(again).not_to be_valid
      expect(again).not_to be_finished
      expect(again.question.key).to eq("location")
      expect(again.problem).to eq(:not_found)
      expect(again.answer_to(again.question).text).to eq("919 Pandora Ave")
    end

    it "goes on in name order, each service once, when the address service is down" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable)
      service("Both", meals, food_banks)
      done = moved("next", categories: ["food"], location: place)

      expect(done).to be_finished
      expect(done).to be_missing_distances
      expect(done.services.map(&:name)).to eq(["Both", "Far meals", "Near meals", "Unknown meals"])
    end

    it "goes on in name order without calling the address service when lookups aren't allowed" do
      done = moved("next", location: place, lookup: false)

      expect(done).to be_finished
      expect(done).to be_missing_distances
      expect(Geocoder).not_to have_received(:locate)
    end

    it "isn't missing distances when the place was skipped" do
      expect(moved("skip", location: place)).not_to be_missing_distances
    end

    it "sorts by distance from a device's location, without looking anything up" do
      done = moved("next", categories: ["food"], location: {"device" => "1", "lat" => "48.42", "lng" => "-123.36"})

      expect(done.services.map(&:name)).to eq(["Near meals", "Far meals", "Unknown meals"])
      expect(done).not_to be_missing_distances
      expect(Geocoder).not_to have_received(:locate)
    end

    it "says when a move would look a place up" do
      asked = described_class.new(answers: {"location" => place}, step: "location")

      expect(["next", nil].map { |direction| asked.lookup_needed?(direction) }).to eq([true, true])
      expect(%w[show back skip].map { |direction| asked.lookup_needed?(direction) }).to all(be(false))
      expect(described_class.new(answers: {"location" => located}, step: "location").lookup_needed?("next")).to be(false)
      expect(described_class.new(answers: {"location" => place}, step: "categories").lookup_needed?("next")).to be(false)
      unreadable = {"categories" => ["unknown"], "location" => place}
      expect(described_class.new(answers: unreadable, step: "location").lookup_needed?("next")).to be(false)
    end
  end

  # The age question is only in specs. It proves one can be added with config and a filter.
  describe "a question about a service's details" do
    before do
      use_age_question
      service("Youth meals", meals, additional_details: {"age_range" => {"min" => 13, "max" => 18}})
      service("Adult meals", meals, additional_details: {"Ages" => "19+"})
      service("Young adult meals", meals, additional_details: {"ages" => "15-25"})
      service("Anyone's meals", meals)
      service("Unclear meals", meals, additional_details: {"ages" => "some ages"})
      service("Adult shelter", shelters, additional_details: {"ages" => "19+"})
    end

    it "hides only services whose known ages rule the person out" do
      expect(names("categories" => ["food"], "age" => ["under_19"]))
        .to eq(["Anyone's meals", "Unclear meals", "Young adult meals", "Youth meals"])
      expect(names("categories" => ["food"], "age" => ["19_up"]))
        .to eq(["Adult meals", "Anyone's meals", "Unclear meals", "Young adult meals"])
    end

    it "hides nothing when skipped" do
      expect(names("categories" => ["food"])).to eq(names("categories" => ["food"], "age" => []))
      expect(names("categories" => ["food"]).size).to eq(5)
    end

    it "combines with every other answer, in any order" do
      place = {"device" => "1", "lat" => "48.42", "lng" => "-123.36"}
      Service.find_by!(name: "Youth meals").update!(address_attributes: {lat: 48.42, lng: -123.36})

      expected = ["Youth meals", "Anyone's meals", "Unclear meals", "Young adult meals"]
      expect(names("categories" => ["food"], "location" => place, "age" => ["under_19"])).to eq(expected)
      expect(names("age" => ["under_19"], "location" => place, "categories" => ["food"])).to eq(expected)
    end

    it "lets an answer put services first instead of hiding them" do
      ranking = Class.new(Questionnaire::Filter) do
        def rank(service)
          (ResourceAttributes.new(service).age_range == (13..18)) ? -1 : 0
        end
      end
      use_age_question(filter: ranking)

      expect(names("categories" => ["food"], "age" => ["under_19"]))
        .to eq(["Youth meals", "Adult meals", "Anyone's meals", "Unclear meals", "Young adult meals"])
    end
  end

  describe "a question that requires details" do
    let(:keys) { described_class.new.questions.map(&:key) }

    def add_ages
      service("Adult meals", meals, additional_details: {"ages" => "19+"})
    end

    it "is hidden while no service has them" do
      use_age_question(requires: "age_range")
      service("Meals", meals, additional_details: {"ages" => "youth"})

      expect(keys).to eq(%w[categories location])
    end

    it "appears once one visible service has them" do
      use_age_question(requires: "age_range")
      add_ages

      expect(keys).to eq(%w[categories location age])
    end

    it "isn't hidden by what someone answers" do
      use_age_question(requires: "age_range")
      add_ages

      # Nothing in the chosen category has ages.
      expect(described_class.new(answers: {"categories" => ["shelter"]}).questions.map(&:key)).to include("age")
    end

    it "finishes after the last question that isn't hidden" do
      use_age_question(requires: "age_range")
      questionnaire = described_class.new(step: "location")
      questionnaire.move("skip")

      expect(questionnaire).to be_finished
    end

    it "ignores an answer to a question that has been hidden, and keeps the others" do
      use_age_question(requires: "age_range")
      service("Meals", meals)
      service("Shelter", shelters)

      [["under_19"], ["unknown"], "x"].each do |age|
        hidden = described_class.new(answers: {"categories" => ["food"], "age" => age}, step: "location")
        expect(hidden).to be_valid
        expect(hidden.services.map(&:name)).to eq(["Meals"])
      end
    end

    it "goes to the first question when the one someone was on has been hidden, keeping answers" do
      use_age_question(requires: "age_range")
      questionnaire = described_class.new(answers: {"categories" => ["food"], "age" => ["under_19"]}, step: "age")
      questionnaire.move("next")

      expect(questionnaire.question.key).to eq("categories")
      expect(questionnaire).not_to be_finished
      expect(questionnaire.answer_to(questionnaire.question).options.map(&:key)).to eq(["food"])
    end

    it "is asked next when it appears partway through" do
      use_age_question(requires: "age_range")
      add_ages
      questionnaire = described_class.new(answers: {"categories" => ["food"]}, step: "location")
      questionnaire.move("skip")

      expect(questionnaire.question.key).to eq("age")
      expect(questionnaire).not_to be_finished
    end

    it "must name something that can be read" do
      expect { use_age_question(requires: "shoe_size") }.to raise_error(KeyError, /shoe_size/)
    end

    it "can't be the only kind of question" do
      entry = AgeQuestion::ENTRY.merge("requires" => "age_range", "filter" => "CategoryFilter",
        "options" => [{"key" => "a", "label" => "A"}])

      expect { questions_from({"questions" => [entry]}.to_yaml) }.to raise_error(ArgumentError, /every question/)
    end

    it "looks at no services when no question requires anything" do
      expect(Service).not_to receive(:visible)

      described_class.new
    end
  end
end
