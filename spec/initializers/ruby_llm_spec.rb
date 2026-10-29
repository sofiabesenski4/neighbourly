require "rails_helper"

RSpec.describe "RubyLLM environment configuration" do
  let(:configuration) { RubyLLM::Configuration.new }
  let(:environment) { {} }

  before do
    # Evaluate the initializer against isolated settings without changing the
    # running app's configuration or installing the local-only TLS workaround.
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    allow(ENV).to receive(:[]).and_call_original
    %w[OPENAI_API_KEY ANTHROPIC_API_KEY OPENAI_API_BASE DEFAULT_MODEL EMBEDDING_MODEL MODEL_REGISTRY_FILE].each do |key|
      allow(ENV).to receive(:[]).with(key).and_return(environment[key])
    end
    allow(RubyLLM).to receive(:configure).and_yield(configuration)

    load Rails.root.join("config/initializers/ruby_llm.rb")
  end

  context "without overrides" do
    it "uses direct-provider models and the standard registry" do
      expect(configuration.default_model).to eq("claude-haiku-4-5")
      expect(configuration.default_embedding_model).to eq("text-embedding-3-small")
      expect(configuration.model_registry_file).to eq("models.json")
      expect(configuration.openai_api_base).to be_nil
      expect(configuration.openai_protocol).to eq(RubyLLM::Configuration.new.openai_protocol)
    end

    it "does not substitute test credentials in production" do
      expect(configuration.openai_api_key).to be_nil
      expect(configuration.anthropic_api_key).to be_nil
    end
  end

  context "with playground overrides" do
    let(:environment) do
      {
        "OPENAI_API_KEY" => "playground-test-key",
        "OPENAI_API_BASE" => "https://playground.example.test/v1",
        "DEFAULT_MODEL" => "qwen3-6-35b-a3b-vllm",
        "EMBEDDING_MODEL" => "nomic-embed-text-cpu",
        "MODEL_REGISTRY_FILE" => "config/uvic_models.json"
      }
    end

    it "uses the configured endpoint, models, registry, and Chat Completions protocol" do
      expect(configuration.openai_api_key).to eq("playground-test-key")
      expect(configuration.openai_api_base).to eq("https://playground.example.test/v1")
      expect(configuration.openai_protocol).to eq(:chat_completions)
      expect(configuration.default_model).to eq("qwen3-6-35b-a3b-vllm")
      expect(configuration.default_embedding_model).to eq("nomic-embed-text-cpu")
      expect(configuration.model_registry_file).to eq("config/uvic_models.json")
    end
  end

  context "with direct-provider credentials and a chat model override" do
    let(:environment) do
      {
        "OPENAI_API_KEY" => "openai-test-key",
        "ANTHROPIC_API_KEY" => "anthropic-test-key",
        "DEFAULT_MODEL" => "another-chat-model"
      }
    end

    it "changes the chat model independently of the embedding model" do
      expect(configuration.openai_api_key).to eq("openai-test-key")
      expect(configuration.anthropic_api_key).to eq("anthropic-test-key")
      expect(configuration.default_model).to eq("another-chat-model")
      expect(configuration.default_embedding_model).to eq("text-embedding-3-small")
      expect(configuration.openai_api_base).to be_nil
    end
  end

  context "with blank overrides" do
    let(:environment) do
      %w[OPENAI_API_BASE DEFAULT_MODEL EMBEDDING_MODEL MODEL_REGISTRY_FILE].to_h { |key| [key, " "] }
    end

    it "falls back to direct-provider defaults" do
      expect(configuration.default_model).to eq("claude-haiku-4-5")
      expect(configuration.default_embedding_model).to eq("text-embedding-3-small")
      expect(configuration.model_registry_file).to eq("models.json")
      expect(configuration.openai_api_base).to be_nil
      expect(configuration.openai_protocol).to eq(RubyLLM::Configuration.new.openai_protocol)
    end
  end
end
