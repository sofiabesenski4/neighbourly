require "rails_helper"

RSpec.describe ChatModelAvailability do
  let(:config) { RubyLLM::Configuration.new }
  let(:openai_model) { RubyLLM::Model.new(id: "gpt-test", name: "OpenAI chat", provider: "openai") }
  let(:anthropic_model) { RubyLLM::Model.new(id: "claude-test", name: "Anthropic chat", provider: "anthropic") }
  let(:models) { RubyLLM::Models.new([openai_model, anthropic_model]) }
  let(:availability) { described_class.new(models: models, config: config) }

  it "offers models only from configured providers" do
    config.openai_api_key = "configured-for-test"

    expect(availability.all).to eq([openai_model])
  end

  it "does not treat whitespace credentials as configured" do
    config.openai_api_key = "   "
    config.anthropic_api_key = ""

    expect(availability.all).to be_empty
  end

  it "keeps custom OpenAI-compatible models without adding the bundled catalog" do
    config.openai_api_key = "configured-for-test"
    config.openai_api_base = "https://example.com/v1"
    custom_model = RubyLLM::Model.new(id: "qwen-uvic", name: "UVic Qwen", provider: "openai")
    embedding_model = RubyLLM::Model.new(id: "nomic-embed", name: "Embedding", provider: "openai", modalities: {input: ["text"], output: ["embeddings"]})
    custom_models = RubyLLM::Models.new([custom_model, embedding_model])

    expect(described_class.new(models: custom_models, config: config).all).to eq([custom_model])
  end

  it "respects provider-specific authentication requirements" do
    azure_model = RubyLLM::Model.new(id: "azure-chat", name: "Azure chat", provider: "azure")
    config.azure_api_base = "https://example.com/openai/v1"
    registry = RubyLLM::Models.new([azure_model])

    expect(described_class.new(models: registry, config: config).all).to be_empty

    config.azure_ai_auth_token = "configured-for-test"
    expect(described_class.new(models: registry, config: config).all).to eq([azure_model])
  end

  it "allows an explicitly configured local provider without requiring an API key" do
    local_model = RubyLLM::Model.new(id: "local-chat", name: "Local chat", provider: "ollama")
    config.ollama_api_base = "http://localhost:11434"

    expect(described_class.new(models: RubyLLM::Models.new([local_model]), config: config).all).to eq([local_model])
  end

  it "excludes entries whose provider is not registered" do
    unknown_model = RubyLLM::Model.new(id: "unknown-chat", name: "Unknown chat", provider: "unknown-provider")

    expect(described_class.new(models: RubyLLM::Models.new([unknown_model]), config: config).all).to be_empty
  end

  it "sorts choices by provider and model name" do
    config.openai_api_key = "configured-for-test"
    config.anthropic_api_key = "configured-for-test"
    another_model = RubyLLM::Model.new(id: "another-openai", name: "Another chat", provider: "openai")
    registry = RubyLLM::Models.new([openai_model, another_model, anthropic_model])

    expect(described_class.new(models: registry, config: config).all).to eq([anthropic_model, another_model, openai_model])
  end

  it "resolves an available model with an optional provider restriction" do
    config.openai_api_key = "configured-for-test"

    expect(availability.find(openai_model.id)).to eq(openai_model)
    expect(availability.find(openai_model.id, provider: :openai)).to eq(openai_model)
    expect(availability.find(openai_model.id, provider: :anthropic)).to be_nil
    expect(availability.find(anthropic_model.id)).to be_nil
  end

  it "checks each provider independently when model IDs overlap" do
    config.anthropic_api_key = "configured-for-test"
    shared_id = RubyLLM::Model.new(id: openai_model.id, name: "Other provider chat", provider: "anthropic")
    registry = RubyLLM::Models.new([openai_model, shared_id])

    expect(described_class.new(models: registry, config: config).find(openai_model.id)).to eq(shared_id)
  end

  it "rechecks configuration when a new availability instance is created" do
    expect(availability.all).to be_empty
    config.openai_api_key = "configured-for-test"

    expect(described_class.new(models: models, config: config).all).to eq([openai_model])
  end
end
