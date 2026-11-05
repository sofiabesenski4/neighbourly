class Document < ApplicationRecord
  belongs_to :source
  has_many :document_messages, dependent: :destroy
  has_many :messages, through: :document_messages
  has_many :reports, dependent: :destroy
  has_and_belongs_to_many :categories, -> { order(:name) }

  has_neighbors :embedding

  validates :content, presence: true

  # Skipped when the caller already embedded the new content.
  before_save :generate_embedding, if: -> { content_changed? && !embedding_changed? }

  # Together these keep a resource's coordinates in step with its address. They
  # live on the model so that every way of saving a resource gets the same
  # behaviour: the form, source imports and the console.
  before_save :keep_coordinates_for_same_address, if: :metadata_changed?
  # after_commit, not after_save, so the job can't run before the data it needs
  # is visible to the worker, or be queued for a save that gets rolled back.
  after_commit :queue_geocoding, on: [:create, :update], if: :needs_geocoding?

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

  # Where the resource is, as a GeoPoint, or nil when that isn't known. A resource
  # has no coordinates if it has no street address, its lookup hasn't finished or
  # the geocoder found no trustworthy match. Callers must handle nil.
  #
  # Values are stored in metadata by GeocodeDocumentJob, or supplied directly by
  # an import. Imported files can contain anything, so a value that isn't a number
  # counts as unknown rather than raising an error while printing.
  def coordinates
    lat = Float(metadata["lat"], exception: false)
    lng = Float(metadata["lng"], exception: false)
    GeoPoint.new(lat: lat, lng: lng) if lat && lng
  end

  # The text to send to the geocoder, like "919 Pandora Ave, Victoria, BC", or nil
  # when this resource can't be looked up.
  def geocoding_query
    self.class.geocoding_query_for(metadata)
  end

  # Takes the metadata as an argument so keep_coordinates_for_same_address can
  # compare the address before and after an edit. A resource with only a city gets
  # no query, because that could only match the middle of town.
  def self.geocoding_query_for(metadata)
    address = metadata["address"].to_s.strip
    [address, metadata["city"].presence, "BC"].compact.join(", ") if address.present?
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

  # The resource form and source imports build metadata from scratch on every
  # save, which would erase stored coordinates each time someone fixed a typo in a
  # phone number. If the address is unchanged, copy the old coordinates forward so
  # we don't repeat the lookup. If it changed, they're left behind on purpose:
  # they describe the old address, and needs_geocoding? will queue a new lookup.
  def keep_coordinates_for_same_address
    # New coordinates in this save, such as from an import, take priority.
    return if metadata["lat"].present? || metadata["lng"].present?
    return unless metadata_was&.key?("lat")
    return unless self.class.geocoding_query_for(metadata_was) == geocoding_query

    self.metadata = metadata.merge(metadata_was.slice("lat", "lng"))
  end

  # Only a save that changed metadata can need a lookup. Saves that touch nothing
  # location-related, like changing categories, are skipped by this first check.
  def needs_geocoding?
    saved_change_to_metadata? && geocoding_query.present? && coordinates.nil?
  end

  def queue_geocoding
    GeocodeDocumentJob.perform_later(self)
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
