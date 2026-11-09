module ChatResponsesHelper
  def chat_sync_version(record)
    timestamp = record&.updated_at
    timestamp ? timestamp.to_i * 1_000_000 + timestamp.usec : 0
  end

  def message_sync_enrichment(message)
    return "" unless message.role == "assistant"

    [message.rag_documents.map(&:id).sort.join(","), message.ruby_llm_usages.map(&:id).sort.join(",")].join(":")
  end
end
