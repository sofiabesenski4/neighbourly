module ContentPipeline
  class Embedder
    # Matches the documents.embedding vector(1536) column.
    DIMENSIONS = 1536

    def initialize(model: nil)
      @model = model || RubyLLM.config.default_embedding_model
    end

    # Smaller models (e.g. nomic-embed-text, 768 dims) are zero-padded to fit the
    # column. Trailing zeros leave cosine distance unchanged, so search results
    # are the same as at the model's native size.
    def embed(input)
      vector = RubyLLM.embed(input, model: @model).vectors
      vector + Array.new(DIMENSIONS - vector.size, 0.0)
    end

    def self.embed(input)
      new.embed(input)
    end
  end
end
