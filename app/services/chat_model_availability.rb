class ChatModelAvailability
  def initialize(models: RubyLLM.models, config: RubyLLM.config)
    @models = models
    @config = config
  end

  def all
    @all ||= @models.chat_models.all.select { |model| configured_provider?(model.provider_class) }
      .sort_by { |model| [model.provider.to_s, model.name.to_s] }
  end

  def find(model_id, provider: nil)
    all.find do |model|
      model.id == model_id && (provider.nil? || model.provider.to_s == provider.to_s)
    end
  end

  private

  def configured_provider?(provider)
    provider && provider.configured?(@config).present? &&
      provider.configuration_requirements.all? { |requirement| @config.public_send(requirement).present? }
  end
end
