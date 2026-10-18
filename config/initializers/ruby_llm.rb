# Placeholder credential used only in test. RubyLLM raises ConfigurationError as
# soon as a provider is resolved with a blank key, which breaks any spec that
# builds a Chat or generates an embedding. Tests never reach the network
# (WebMock blocks it), so a placeholder is enough to get past the guard. In
# every other environment a missing key stays nil and the error surfaces.
placeholder_key = "test-placeholder-key" if Rails.env.test?

# UVic's AI Learning Lab ends streamed replies by closing the TLS connection
# without a close_notify alert. curl tolerates that, but OpenSSL 3 raises
# "SSL_read: unexpected eof" and aborts every streamed chat. Tolerate it only
# locally, and only when pointed at a custom OpenAI-compatible endpoint.
if Rails.env.local? && ENV["OPENAI_API_BASE"].present?
  OpenSSL::SSL::SSLContext.prepend(Module.new do
    def set_params(params = {})
      super.tap { self.options |= OpenSSL::SSL::OP_IGNORE_UNEXPECTED_EOF }
    end
  end)
end

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"].presence || placeholder_key
  config.openai_api_key = ENV["OPENAI_API_KEY"].presence || placeholder_key

  # Overridable so local development can point the OpenAI provider at another
  # OpenAI-compatible API, such as UVic's AI Learning Lab with
  # MODEL_REGISTRY_FILE=config/uvic_models.json. Unset, these fall back to
  # OpenAI, Claude Haiku, and the bundled model registry.
  config.openai_api_base = ENV["OPENAI_API_BASE"].presence
  config.default_model = ENV["DEFAULT_MODEL"].presence || "claude-haiku-4-5"
  config.default_embedding_model = ENV["EMBEDDING_MODEL"].presence || "text-embedding-3-small"

  config.model_registry_file = ENV["MODEL_REGISTRY_FILE"].presence || "models.json"
end
