class ChatResponseJob < ApplicationJob
  def perform(chat_id, content)
    chat = Chat.find(chat_id)

    if chat.use_rag?
      result = RagContext.new.augment(content)
      prompt = result.prompt
      rag_documents = result.documents
    else
      prompt = content
      rag_documents = []
    end

    chat.ask(prompt) do |chunk|
      if chunk.content && !chunk.content.empty?
        message = chat.messages.last
        message.broadcast_append_chunk(chunk.content)
      end
    end

    if rag_documents.any?
      user_message = chat.messages.where(role: "user").last
      assistant_message = chat.messages.where(role: "assistant").last

      user_message&.update!(content: content)
      user_message&.rag_documents = rag_documents
      assistant_message&.rag_documents = rag_documents

      user_message&.broadcast_rag_context
      assistant_message&.broadcast_rag_context
    end
  rescue RubyLLM::Error, Faraday::Error
    # RubyLLM deletes the empty reply when the API call fails, which would
    # leave the user's message sitting there unanswered. Say so, then re-raise
    # so the failure is still logged and reported.
    chat.broadcast_reply_failed
    raise
  end
end
