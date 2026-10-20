class Document < ApplicationRecord
  belongs_to :source
  has_many :document_messages, dependent: :destroy
  has_many :messages, through: :document_messages
  has_many :reports, dependent: :destroy

  has_neighbors :embedding

  validates :content, presence: true

  before_save :generate_embedding, if: :content_changed?

  scope :with_embeddings, -> { where.not(embedding: nil) }

  # Documents tagged with a ResourceCategory key, e.g. in_category("food").
  scope :in_category, ->(key) { where("metadata @> ?", {resource_categories: [key]}.to_json) }

  scope :search_by_similarity, ->(query_text, limit: 5) {
    query_embedding = ContentPipeline::Embedder.embed(query_text)
    nearest_neighbors(:embedding, query_embedding, distance: :cosine)
      .includes(:source)
      .limit(limit)
  }

  private

  def generate_embedding
    return if content.blank?

    self.embedding = ContentPipeline::Embedder.embed(content)
  rescue RubyLLM::Error => e
    errors.add(:base, "Failed to generate embedding: #{e.message}")
    throw :abort
  end
end
