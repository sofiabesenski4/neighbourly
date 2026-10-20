# The fixed set of categories resources are grouped under, such as the
# sections of a print-out. Source data tags each resource with free-text
# labels ("Meals", "Food bank"), so each category lists the labels that
# belong to it. Add a source's new labels here to have them grouped.
class ResourceCategory < Data.define(:key, :name, :labels)
  ALL = [
    new(key: "food", name: "Food", labels: [
      "Meals", "Food bank", "Food support"
    ]),
    new(key: "shelter", name: "Shelter & housing", labels: [
      "Emergency shelter", "Shelter", "Seasonal shelter", "Youth emergency shelter",
      "Shelter and drop-in support", "Transition house", "Transitional housing"
    ]),
    new(key: "health", name: "Health", labels: [
      "Health services", "Medical support", "Primary health care", "Nursing care",
      "Dental care", "Foot care"
    ]),
    new(key: "harm_reduction", name: "Harm reduction", labels: [
      "Harm reduction", "Naloxone", "Naloxone training", "Overdose prevention",
      "Supervised consumption", "Substance use support"
    ]),
    new(key: "hygiene", name: "Hygiene & essentials", labels: [
      "Showers", "Laundry", "Hair cuts", "Storage", "Clothing",
      "Clothing and household items", "Free phone", "ID replacement", "Transportation support"
    ]),
    new(key: "legal", name: "Legal", labels: [
      "Legal advice", "Legal clinics", "Legal support", "Civil law", "Criminal law", "Family law"
    ]),
    new(key: "counselling", name: "Counselling & support", labels: [
      "Counselling", "Counselling and referrals", "Peer support", "Support groups", "Outreach"
    ]),
    new(key: "family", name: "Family & youth", labels: [
      "Family services", "Family violence support", "Youth and family mediation"
    ])
  ].freeze

  def self.all
    ALL
  end

  # Returns the keys of the categories the given labels belong to, in the
  # order of ALL. Matching ignores case and surrounding whitespace, and
  # labels that belong to no category are skipped.
  def self.keys_for(labels)
    wanted = Array(labels).map { |label| normalize(label) }
    all.select { |category| category.labels.any? { |label| wanted.include?(normalize(label)) } }.map(&:key)
  end

  # Returns the categories with the given keys, in the order of ALL.
  # Unknown keys are skipped.
  def self.with_keys(keys)
    keys = Array(keys).map(&:to_s)
    all.select { |category| keys.include?(category.key) }
  end

  def self.normalize(label)
    label.to_s.strip.downcase
  end
  private_class_method :normalize
end
