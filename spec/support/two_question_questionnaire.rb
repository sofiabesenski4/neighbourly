# A questionnaire with two questions, for specs about moving between them. The real config
# can change without breaking those specs, and they don't depend on what it asks.
#
# The first question uses the real CategoryFilter. The second is a radio question that
# narrows by organization, with a filter that exists only here. CategorySearch already
# takes organizations, so the two answers combine in a real search.
#
# Include the module and call use_two_questions. Required by the specs that need it.
module TwoQuestionQuestionnaire
  class OrganizationFilter < Questionnaire::Filter
    def self.search_keys
      [:organizations]
    end

    def search_options
      {organizations: Organization.where(name: options.map(&:label)).pluck(:id).map(&:to_s)}
    end
  end

  CONFIG = <<~YAML
    questions:
      - key: needs
        title: What do you need?
        type: checkboxes
        filter: CategoryFilter
        options:
          - { key: food, label: Food, categories: [Meals] }
          - { key: shelter, label: A place to stay, categories: [Shelters] }
      - key: who
        title: Who would you like to go to?
        type: radio
        filter: OrganizationFilter
        options:
          - { key: our_place, label: Our Place }
          - { key: the_mustard_seed, label: The Mustard Seed }
  YAML

  # Creates the records the questions are about, and makes every Questionnaire ask them.
  # Our Place and The Mustard Seed each offer food and a place to stay.
  def use_two_questions
    stub_const("Questionnaire::FILTERS", Questionnaire::FILTERS.merge("OrganizationFilter" => OrganizationFilter))
    questions = Tempfile.create(["questionnaire", ".yml"]) do |file|
      file.write(CONFIG)
      file.flush
      Questionnaire.questions_from(file.path)
    end
    allow(Questionnaire).to receive(:questions_from).and_return(questions)

    meals = Category.create!(name: "Meals")
    shelters = Category.create!(name: "Shelters")
    source = Source.create!(name: "Local guide", source_type: "csv")
    ["Our Place", "The Mustard Seed"].each do |name|
      organization = Organization.create!(name: name)
      source.services.create!(name: "#{name} meals", categories: [meals], organization: organization)
      source.services.create!(name: "#{name} beds", categories: [shelters], organization: organization)
    end
  end
end
