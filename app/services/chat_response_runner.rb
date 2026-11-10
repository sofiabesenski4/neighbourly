class ChatResponseRunner
  def initialize(response_id, attempt_token: nil)
    @response_id = response_id
    @attempt_token = attempt_token
  end

  def call
    @response = ChatResponse.find(@response_id)
    @response.expected_attempt_token = @attempt_token || @response.attempt_token
    return unless @response.claim!

    @chat = @response.chat
    @chat.with_model(@response.model_id, provider: @response.provider)
    @chat.to_llm.cancellation_checker = -> { @response.cancellation_requested? }
    checkpoint!
    result = RagContext.new.augment(@response.user_message.content)
    @documents = result.documents
    checkpoint!
    @chat.with_instructions(result.instructions, append: true, persist: false) if result.instructions.present?
    raise RubyLLM::CancelledError unless @response.start_writing!

    @chat.before_message do
      # This is the SDK's own newly-created placeholder, not another record
      # loaded with .last. Its in-memory content prevents SDK failure cleanup
      # from deleting text that has already streamed to the user.
      @assistant = @chat.messages.target.last
      raise "The assistant placeholder was not created" unless @assistant&.role == "assistant"

      @assistant.chat_response_run = @response
      @response.while_running { @response.update!(assistant_message: @assistant) }
    end

    @chat.complete do |chunk|
      next if chunk.content.blank?

      @response.while_running do
        @assistant.content = @assistant.content.to_s + chunk.content
        @assistant.broadcast_append_chunk(chunk.content)
        @response.heartbeat!
      end
    end

    checkpoint!
    @response.while_running { link_documents }
    raise RubyLLM::CancelledError unless @response.complete!

    ChatTitleJob.perform_later(@chat.id) if @chat.title.blank?
  rescue RubyLLM::CancelledError
    record_cancellation
  rescue ActiveRecord::RecordNotFound => error
    # The user can delete the conversation between a checkpoint and a lock.
    unless @response && !ChatResponse.exists?(@response.id)
      record_failure(error)
      raise
    end
  rescue RubyLLM::Error, Faraday::Error => error
    record_failure(error)
  rescue => error
    record_failure(error)
    raise
  end

  private

  def checkpoint!
    raise RubyLLM::CancelledError if @response.cancellation_requested?
  end

  def record_cancellation
    return unless @response&.persisted?

    @response.with_lock do
      return unless @response.current_attempt? && @response.cancelling?

      persist_partial
      @response.acknowledge_cancellation!
    end
  rescue ActiveRecord::RecordNotFound
    # Deleting a conversation also removes its response and SDK placeholder.
    nil
  end

  def record_failure(error)
    return unless @response&.persisted?

    @response.while_running do
      persist_partial
      message = @response.searching? ? ChatResponse::LOOKUP_FAILED_MESSAGE : ChatResponse::FAILED_MESSAGE
      @response.fail!(message)
    end
    Rails.error.report(error, context: {chat_id: @response.chat_id, chat_response_id: @response.id})
  rescue RubyLLM::CancelledError, ActiveRecord::RecordNotFound
    record_cancellation
  end

  def persist_partial
    return unless @assistant&.persisted? && @assistant.content.present?
    return unless Message.visible_in_conversation.exists?(id: @assistant.id)

    @assistant.save!
    link_documents
  end

  def link_documents
    return if @documents.blank?

    @response.user_message.rag_documents = @documents
    if @assistant&.persisted? && Message.visible_in_conversation.exists?(id: @assistant.id)
      @assistant.rag_documents = @documents
      @assistant.broadcast_rag_context
    end
  end
end
