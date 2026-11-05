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
