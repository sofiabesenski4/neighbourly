require "rails_helper"
require "support/age_question"

# Covers what the results page is given: the agreement in docs/questionnaire-results.md. How
# answers find services is in spec/models/questionnaire_spec.rb, and the change button is in
# spec/requests/questionnaires_spec.rb.
RSpec.describe QuestionnaireResults do
  include AgeQuestion

  let(:source) { Source.create!(name: "Local guide", source_type: "csv") }
  let!(:meals) { Category.create!(name: "Meals") }
  let!(:food_banks) { Category.create!(name: "Food Banks") }
  let!(:shelters) { Category.create!(name: "Shelters") }
  let(:place) { {"near" => "919 Pandora Ave"} }
  let(:device) { {"device" => "1", "lat" => "48.42", "lng" => "-123.36"} }

  before { allow(Geocoder).to receive(:locate).and_return(GeoPoint.new(lat: 48.42, lng: -123.36)) }

  def service(name, *categories, **attributes)
    source.services.create!(name: name, categories: categories, **attributes)
  end

  # The results of finishing the questionnaire with these answers.
  def results(**answers)
    questionnaire = Questionnaire.new(answers: answers.transform_keys(&:to_s), step: "location")
    questionnaire.move("next")
    questionnaire.results
  end

  def answers(results)
    results.answers.map { |answer| [answer.key, answer.title, answer.labels] }
  end

  describe "#services" do
    it "has matching services in name order, each once" do
      service("Soup kitchen", meals)
      service("Both", meals, food_banks)
      service("Shelter", shelters)

      expect(results(categories: ["food"]).services.map(&:name)).to eq(["Both", "Soup kitchen"])
    end

    it "has the nearest first, agreeing with the distances on cards, and unknown ones last" do
      service("Far", meals, address_attributes: {lat: 48.50, lng: -123.36})
      service("Unknown", meals)
      service("Near", meals, food_banks, address_attributes: {lat: 48.421, lng: -123.36})
      found = results(categories: ["food"], location: place)

      expect(found.services.map(&:name)).to eq(%w[Near Far Unknown])
      distances = found.services.map { |service| ResourceCard.new(service, origin: found.origin).distance_km }
      expect(distances.last).to be_nil
      expect(distances.compact).to eq(distances.compact.sort).and have_attributes(size: 2)
    end

    it "is empty when nothing matches" do
      service("Shelter", shelters)

      expect(results(categories: ["food"]).services).to eq([])
    end
  end

  describe "#origin" do
    it "is nil when location was skipped" do
      expect(results.origin).to be_nil
      expect(results(location: {"near" => ""}).origin).to be_nil
    end

    it "is the typed place, once it's looked up" do
      expect(results(location: place).origin)
        .to eq(FlyerOrigin.new(label: "919 Pandora Ave", point: GeoPoint.new(lat: 48.42, lng: -123.36)))
    end

    it "is the device's location" do
      expect(results(location: device).origin).to be_located.and have_attributes(label: "your location")
    end

    it "has no point when the address service is down, and cards then show no distance" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable)
      service("Near", meals, address_attributes: {lat: 48.421, lng: -123.36})
      found = results(location: place)

      expect(found.origin).not_to be_located
      expect(ResourceCard.new(found.services.first, origin: found.origin).distance_km).to be_nil
    end
  end

  describe "#missing_distances?" do
    it "is true only when a place was given but couldn't be looked up" do
      expect(results).not_to be_missing_distances
      expect(results(location: place)).not_to be_missing_distances
      expect(results(location: device)).not_to be_missing_distances

      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable)
      expect(results(location: place)).to be_missing_distances
    end
  end

  describe "#answers" do
    it "has each answered question in words, in the order they're asked" do
      expect(answers(results(location: place, categories: %w[shelter food]))).to eq([
        ["categories", "What do you need help with?", ["Food", "A place to stay"]],
        ["location", "Where are you?", ["919 Pandora Ave"]]
      ])
    end

    it "calls the device's location your location, and never gives its coordinates" do
      expect(answers(results(location: device))).to eq([["location", "Where are you?", ["your location"]]])
    end

    it "leaves out skipped questions" do
      expect(results.answers).to eq([])
      expect(answers(results(categories: ["food"])).map(&:first)).to eq(["categories"])
    end

    it "keeps a place that couldn't be looked up" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable)

      expect(answers(results(location: place))).to eq([["location", "Where are you?", ["919 Pandora Ave"]]])
    end

    it "includes any other question, with no change to the results" do
      use_age_question
      questionnaire = Questionnaire.new(answers: {"age" => ["under_19"]}, step: "age")
      questionnaire.move("next")

      expect(answers(questionnaire.results)).to eq([["age", "How old are you?", ["Under 19"]]])
    end
  end

  describe "#hidden_fields" do
    it "carries every answer, including a place already looked up" do
      expect(results(categories: %w[food shelter], location: place).hidden_fields).to contain_exactly(
        ["questionnaire[answers][categories][]", "food"],
        ["questionnaire[answers][categories][]", "shelter"],
        ["questionnaire[answers][location][near]", "919 Pandora Ave"],
        ["questionnaire[answers][location][checked]", "919 Pandora Ave"],
        ["questionnaire[answers][location][lat]", 48.42],
        ["questionnaire[answers][location][lng]", -123.36]
      )
    end

    it "is empty when everything was skipped" do
      expect(results.hidden_fields).to eq([])
    end
  end
end
