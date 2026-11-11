class Document < ApplicationRecord
  belongs_to :source
  has_many :document_messages, dependent: :destroy
  has_many :messages, through: :document_messages
  has_many :reports, dependent: :destroy
  has_and_belongs_to_many :categories, -> { order(:name) }
  # Saved with the resource, so an import or form edit writes both together.
  has_one :address, dependent: :destroy, autosave: true

  has_neighbors :embedding

  validates :content, presence: true

  # Skipped when the caller already embedded the new content.
  before_save :generate_embedding, if: -> { content_changed? && !embedding_changed? }

  scope :with_embeddings, -> { where.not(embedding: nil) }

  scope :in_categories, ->(category_ids) {
    joins(:categories).where(categories: {id: category_ids}).distinct
  }

  def category_names
    categories.map(&:name)
  end

  def category_names=(names)
    normalized_names = Array(names).map { |name| name.to_s.strip }.reject(&:blank?).uniq
    self.categories = Category.where(name: normalized_names)
  end

  # Sets the address from what a source or the resource form gives. Blank
  # values clear a field. Coordinates are only replaced when given, so a lookup
  # already made for the same address is kept. Nothing is created for a
  # resource that has no address details at all.
  def assign_address(street_address: nil, city: nil, phone: nil, lat: nil, lng: nil)
    details = {street_address: street_address.presence, city: city.presence, phone: phone.presence}
    return if address.nil? && details.values.none? && lat.blank? && lng.blank?

    (address || build_address).assign_attributes(details.merge({lat: lat, lng: lng}.compact_blank))
  end

  # The resource's address, or for a resource saved before addresses had their
  # own table, one read from its metadata. The second kind is never saved.
  def location
    address || legacy_address
  end

  # Where the resource is, as a GeoPoint, or nil when that isn't known. Callers
  # must handle nil.
  def coordinates
    location.coordinates
  end

  # Enrichment finds the row's address, so geocoding waits for it rather than
  # looking up whatever the row's columns happen to give.
  def awaiting_enrichment?
    enriched_at.nil? && source.enrich_documents?
  end

  # Resources geocoded before addresses had their own table have lat and lng
  # in their metadata. Those are not part of the row as uploaded, so they do
  # not make it look changed. Coordinates the row itself supplied are still
  # compared.
  def self.same_row?(stored, row)
    stored.except(*(%w[lat lng] - row.keys)) == row
  end

  # A moderator accepted a report, so the resource is kept out of search.
  def removal_accepted?
    reports.where(status: "valid").exists?
  end

  def save_with_category_names(names)
    persist_with_categories(names) { save }
  end

  def save_with_category_names!(names)
    persist_with_categories(names) { save! }
  end

  scope :search_by_similarity, ->(query_text, limit: 5) {
    query_embedding = ContentPipeline::Embedder.embed(query_text)
    nearest_neighbors(:embedding, query_embedding, distance: :cosine)
      .includes(:source)
      .limit(limit)
  }

  private

  def legacy_address
    data = metadata || {}
    Address.new(
      street_address: data["address"].presence,
      city: data["city"].presence,
      phone: Array(data["phone"]).compact_blank.join(", ").presence,
      lat: data["lat"],
      lng: data["lng"]
    ).tap(&:readonly!)
  end

  def persist_with_categories(names)
    result = nil
    self.class.transaction do
      self.category_names = names
      result = yield
      raise ActiveRecord::Rollback if result == false
    end
    association(:categories).reset if result == false
    result
  end

  def generate_embedding
    return if content.blank?

    self.embedding = ContentPipeline::Embedder.embed(content)
  rescue RubyLLM::Error => e
    errors.add(:base, "Failed to generate embedding: #{e.message}")
    throw :abort
  end
end
