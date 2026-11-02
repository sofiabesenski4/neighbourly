class ChatResponseRunner
  def initialize(response_id)
    @response_id = response_id
  end

  def call
    @response = ChatResponse.find(@response_id)
    return unless @response.claim!

    @chat = @response.chat
    @chat.with_model(@response.model_id, provider: @response.provider)
    result = RagContext.new.augment(@response.user_message.content)
    @documents = result.documents
    @chat.with_instructions(result.instructions, append: true, persist: false) if result.instructions.present?
    @response.update!(status: "writing", heartbeat_at: Time.current)

    @chat.before_message do
      # This is the SDK's own newly-created placeholder, not another record
      # loaded with .last. Its in-memory content prevents SDK failure cleanup
      # from deleting text that has already streamed to the user.
      @assistant = @chat.messages.target.last
      raise "The assistant placeholder was not created" unless @assistant&.role == "assistant"

      @response.update!(assistant_message: @assistant)
    end

    @chat.complete do |chunk|
      next if chunk.content.blank?

      @assistant.content = @assistant.content.to_s + chunk.content
      @assistant.broadcast_append_chunk(chunk.content)
      @response.heartbeat!
    end

    link_documents
    if @response.complete! && @chat.title.blank?
      ChatTitleJob.perform_later(@chat.id)
    end
  rescue RubyLLM::Error, Faraday::Error => error
    record_failure(error)
  rescue => error
    record_failure(error)
    raise
  end

  private

  def record_failure(error)
    return unless @response&.persisted?

    if @assistant&.persisted? && @assistant.content.present?
      @assistant.save!
      link_documents
    end
    message = @response.searching? ? ChatResponse::LOOKUP_FAILED_MESSAGE : ChatResponse::FAILED_MESSAGE
    @response.fail!(message)
    Rails.error.report(error, context: {chat_id: @response.chat_id, chat_response_id: @response.id})
  end

  def link_documents
    return if @documents.blank?

    @response.user_message.rag_documents = @documents
    if @assistant&.persisted?
      @assistant.rag_documents = @documents
      @assistant.broadcast_rag_context
    end
  end
end
