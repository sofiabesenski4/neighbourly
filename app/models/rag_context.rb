# Builds augmented prompts by retrieving relevant document context
# via vector similarity search and prepending it to the user's question.
class RagContext
  SYSTEM_PREFIX = <<~PROMPT.freeze
    Use the following reference documents to help answer the user's question.
    If the documents don't contain relevant information, say so and answer
    based on your general knowledge. Always cite your sources by including
    the source name and URL when using reference documents.

    --- REFERENCE DOCUMENTS ---
  PROMPT

  def initialize(limit: 5)
    @limit = limit
  end

  Result = Struct.new(:prompt, :documents)

  def augment(content)
    documents = Document.search_by_similarity(content, limit: @limit)
    return Result.new(prompt: content, documents: []) if documents.empty?

    context_block = documents.map.with_index do |doc, i|
      "[#{i + 1}] #{doc.title} (Source: #{doc.source.name}, URL: #{doc.source.url})\n#{doc.content}"
    end.join("\n\n")

    prompt = "#{SYSTEM_PREFIX}#{context_block}\n--- END REFERENCE DOCUMENTS ---\n\n#{content}"
    Result.new(prompt: prompt, documents: documents.to_a)
  end
end
