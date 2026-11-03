class ChatResponseJob < ApplicationJob
  # Shown when we cannot look up local resources. Answering without them would
  # read as a grounded answer with no sources, so we ask for a fresh start.
  FALLBACK_RESPONSE = "Sorry, something went wrong while looking up local resources for your question. " \
    "Please start a new chat and try again.".freeze

  def perform(chat_id, content)
    chat = Chat.find(chat_id)

    begin
      result = RagContext.new.augment(content)
    rescue RubyLLM::Error, Faraday::Error => e
      Rails.error.report(e, context: {chat_id: chat.id})
      respond_with_fallback(chat, content)
      return
    end

    rag_documents = result.documents

    chat.ask(result.prompt) do |chunk|
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

    chat.broadcast_reply_succeeded
  rescue RubyLLM::Error, Faraday::Error
    # RubyLLM deletes the empty reply when the API call fails, which would
    # leave the user's message sitting there unanswered. Say so, then re-raise
    # so the failure is still logged and reported.
    chat.broadcast_reply_failed
    raise
  end

  private

  def respond_with_fallback(chat, content)
    chat.messages.create!(role: "user", content: content)
    chat.messages.create!(role: "assistant", content: FALLBACK_RESPONSE)
  end
end
