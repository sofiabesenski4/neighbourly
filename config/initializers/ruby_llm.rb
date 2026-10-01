# Placeholder credential used only in test. RubyLLM raises ConfigurationError as
# soon as a provider is resolved with a blank key, which breaks any spec that
# builds a Chat or generates an embedding. Tests never reach the network
# (WebMock blocks it), so a placeholder is enough to get past the guard. In
# every other environment a missing key stays nil and the error surfaces.
placeholder_key = "test-placeholder-key" if Rails.env.test?

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"].presence || placeholder_key
  config.openai_api_key = ENV["OPENAI_API_KEY"].presence || placeholder_key
  config.default_model = "claude-haiku-4-5"
  config.default_embedding_model = "text-embedding-3-small"

  # Use the new association-based acts_as API (recommended)
  config.use_new_acts_as = true

  config.model_registry_file = "models.json"
end
