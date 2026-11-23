require "rails_helper"

# Covers the questionnaire's rules: what the config must contain, how submitted answers are
# read, and which services they find. The HTTP side is in
# spec/requests/questionnaires_spec.rb, and turning categories into IDs is in
# spec/models/questionnaire/category_filter_spec.rb.
RSpec.describe Questionnaire do
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

  describe "#services" do
    it "finds services in any category behind the chosen option" do
      service("Soup kitchen", meals)
      service("Food bank", food_banks)
      service("Shelter", shelters)

      expect(names("categories" => ["food"])).to eq(["Food bank", "Soup kitchen"])
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
      expect(questionnaire.chosen(questionnaire.question).map(&:key)).to eq(["food"])
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
end
