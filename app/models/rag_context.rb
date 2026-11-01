# Retrieves reference instructions separately from the user's question so
# internal context does not become part of the displayed conversation.
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

  Result = Struct.new(:instructions, :documents)

  def augment(content)
    documents = Document.search_by_similarity(content, limit: @limit)
    return Result.new(instructions: nil, documents: []) if documents.empty?

    context_block = documents.map.with_index do |doc, i|
      "[#{i + 1}] #{doc.title} (Source: #{doc.source.name}, URL: #{doc.source.url})\n#{doc.content}"
    end.join("\n\n")

    instructions = "#{SYSTEM_PREFIX}#{context_block}\n--- END REFERENCE DOCUMENTS ---"
    Result.new(instructions: instructions, documents: documents.to_a)
  end
end
