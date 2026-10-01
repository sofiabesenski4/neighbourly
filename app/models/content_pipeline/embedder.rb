module ContentPipeline
  class Embedder
    def initialize(model: nil)
      @model = model || RubyLLM.config.default_embedding_model
    end

    def embed(input)
      result = RubyLLM.embed(input, model: @model)
      result.vectors
    end

    def self.embed(input)
      new.embed(input)
    end
  end
end
