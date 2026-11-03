class Document < ApplicationRecord
  belongs_to :source
  has_many :document_messages, dependent: :destroy
  has_many :messages, through: :document_messages
  has_many :reports, dependent: :destroy
  has_and_belongs_to_many :categories, -> { order(:name) }

  has_neighbors :embedding

  validates :content, presence: true

  before_save :generate_embedding, if: :content_changed?

  scope :with_embeddings, -> { where.not(embedding: nil) }

  # Database categories take precedence over legacy metadata tags.
  scope :in_category, ->(key) {
    terms = ResourceCategory.with_keys([key]).flat_map(&:terms).map { |term| term.strip.downcase }
    categorized = joins(:categories).where("LOWER(TRIM(categories.name)) IN (?)", terms).select(:id)
    legacy = where.not(id: joins(:categories).select(:id))
      .where("metadata @> ?", {resource_categories: [key]}.to_json)
    where(id: categorized).or(legacy)
  }

  def resource_category_keys
    names = category_names
    names.any? ? ResourceCategory.keys_for(names) : Array(metadata["resource_categories"])
  end

  def category_names
    categories.map(&:name)
  end

  def category_names=(names)
    normalized_names = Array(names).map { |name| name.to_s.strip }.reject(&:blank?).uniq
    self.categories = Category.where(name: normalized_names)
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
