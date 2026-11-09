# Loads 20 Greater Victoria street survival resources for local development, so
# the printout and chat have real listings to work with. Loaded from db/seeds.rb
# in development only. The notes say much of this comes from a 2022 guide, so
# hours and intake details may be out of date.
#
# The JSON file is kept exactly as it was supplied. It is in the shape
# ContentPipeline::Parsers::Api reads, so it goes through the same ingestion as an
# API source. Saving each resource calls the embedding API set in your .env, and
# queues a geocoding lookup for its address.
#
# The file's taxonomies are more detailed than the app's categories, and the
# importer only attaches categories whose names match exactly. TAXONOMY_CATEGORIES
# says which category each taxonomy belongs to. Taxonomies with no clear match are
# in UNCATEGORIZED_TAXONOMIES; they stay in each resource's searchable text but get
# no category. A taxonomy in neither list stops the seed, so a changed file can't
# lose categories without anyone noticing.
module GreaterVictoriaResources
  DATA_FILE = Rails.root.join("db/seeds/greater_victoria_street_survival_resources.json")
  SOURCE_NAME = "Greater Victoria street survival resources"

  TAXONOMY_CATEGORIES = {
    "Meals" => ["Meals"],
    "Shelter" => ["Shelters"],
    "Emergency shelter" => ["Shelters"],
    "Seasonal shelter" => ["Shelters"],
    "Shelter and drop-in support" => ["Shelters"],
    "Transition house" => ["Shelters"],
    "Youth emergency shelter" => ["Shelters", "Youth Services"],
    "Youth and family mediation" => ["Youth Services"],
    "Harm reduction" => ["Harm Reduction Resources"],
    "Naloxone" => ["Harm Reduction Resources"],
    "Naloxone training" => ["Harm Reduction Resources"],
    "Overdose prevention" => ["Harm Reduction Resources"],
    "Supervised consumption" => ["Supervised Consumption"],
    "Substance use support" => ["Substance Use Support"],
    "Food bank" => ["Food Banks"],
    "Showers" => ["Showers"],
    "Health services" => ["Health Care"],
    "Primary health care" => ["Health Care"],
    "Medical support" => ["Health Care"],
    "Nursing care" => ["Health Care"],
    "Dental care" => ["Health Care"],
    "Clothing" => ["Clothing"],
    "Clothing and household items" => ["Clothing"],
    "Legal support" => ["Legal Support"],
    "Legal advice" => ["Legal Support"],
    "Legal clinics" => ["Legal Support"],
    "Family law" => ["Legal Support"],
    "Civil law" => ["Legal Support"],
    "Criminal law" => ["Legal Support"],
    "Transitional housing" => ["Housing Services"]
  }.freeze

  UNCATEGORIZED_TAXONOMIES = [
    "Counselling", "Counselling and referrals", "Family services", "Family violence support",
    "Food support", "Foot care", "Free phone", "Hair cuts", "ID replacement", "Laundry",
    "Outreach", "Peer support", "Storage", "Support groups", "Transportation support"
  ].freeze

  def self.seed
    raw = File.read(DATA_FILE)
    records = JSON.parse(raw)
    check_taxonomies(records)
    check_categories

    source = Source.find_or_create_by!(name: SOURCE_NAME, source_type: "api")
    count = ContentPipeline::Ingester.new(source).ingest(raw)

    records.each do |record|
      document = source.documents.find_by!(external_id: record["id"])
      document.save_with_category_names!(categories_for(record))
    end

    puts "Seeded #{count} resources from #{DATA_FILE.basename}"
  end

  def self.categories_for(record)
    Array(record["taxonomies"]).flat_map { |taxonomy| TAXONOMY_CATEGORIES.fetch(taxonomy["name"], []) }.uniq
  end

  def self.check_taxonomies(records)
    known = TAXONOMY_CATEGORIES.keys + UNCATEGORIZED_TAXONOMIES
    unknown = records.flat_map { |record| Array(record["taxonomies"]).pluck("name") }.uniq - known
    return if unknown.empty?

    raise "#{DATA_FILE.basename} has taxonomies with no category mapping: #{unknown.join(", ")}. " \
      "Add them to TAXONOMY_CATEGORIES or UNCATEGORIZED_TAXONOMIES in #{__FILE__}."
  end

  # Categories are matched by name, so a renamed category would silently drop out.
  def self.check_categories
    missing = TAXONOMY_CATEGORIES.values.flatten.uniq - Category.pluck(:name)
    raise "Categories missing from the database: #{missing.join(", ")}" if missing.any?
  end
end

GreaterVictoriaResources.seed
