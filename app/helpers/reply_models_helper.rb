module ReplyModelsHelper
  def reply_model_label(message)
    return unless message.role == "assistant"

    association = message.association(:ruby_llm_usages)
    usage = if association.loaded?
      association.target.select { |entry| entry.operation == "chat" && entry.status == "succeeded" }.max_by(&:id)
    else
      message.ruby_llm_usages.where(operation: "chat", status: "succeeded").reorder(id: :desc).first
    end
    return unless usage

    model = RubyLLM.models.all_including_unlisted.find do |entry|
      entry.provider.to_s == usage.provider && entry.id == usage.model
    end
    model&.label || "#{usage.provider}: #{usage.model}"
  end
end
