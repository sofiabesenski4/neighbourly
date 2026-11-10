class Message < ApplicationRecord
  acts_as_message
  has_many_attached :attachments
  has_many :document_messages, dependent: :destroy
  has_many :rag_documents, through: :document_messages, source: :document

  CONVERSATION_ROLES = %w[user assistant].freeze

  attr_accessor :chat_response_run

  around_save :persist_for_current_response

  scope :visible_in_conversation, -> { where(role: CONVERSATION_ROLES).where.missing(:ruby_llm_tool_calls) }

  after_create_commit :broadcast_conversation_append, if: :conversation_visible?
  after_update_commit :broadcast_conversation_update
  after_destroy_commit :broadcast_conversation_removal, if: -> { CONVERSATION_ROLES.include?(role) }
  after_create_commit :broadcast_initial_chat_title, if: -> { role == "user" && conversation_visible? }

  def conversation_visible?
    CONVERSATION_ROLES.include?(role) && !tool_call?
  end

  def broadcast_append_chunk(content)
    return unless conversation_visible?

    broadcast_safely do
      broadcast_append_to chat.stream_name,
        target: "message_#{id}_content",
        content: ERB::Util.html_escape(content.to_s)
    end
  end

  def broadcast_rag_context
    return unless role == "assistant" && conversation_visible?

    broadcast_safely do
      broadcast_replace_to chat.stream_name,
        target: "message_#{id}_rag_context",
        partial: "messages/rag_context",
        locals: {message: self, show_report_button: true}
    end
  end

  private

  def persist_for_current_response(&block)
    if chat_response_run
      chat_response_run.while_persistable(&block)
    else
      yield
    end
  end

  def broadcast_conversation_append
    broadcast_safely { broadcast_append_to chat.stream_name, target: "messages" }
  end

  def broadcast_conversation_update
    if conversation_visible?
      broadcast_safely { broadcast_replace_to chat.stream_name }
    elsif CONVERSATION_ROLES.include?(role_before_last_save)
      # An assistant placeholder can turn into a tool call after streaming.
      # Remove its visible shell without rendering the internal payload.
      broadcast_conversation_removal
    end
  end

  def broadcast_conversation_removal
    broadcast_safely { broadcast_remove_to chat.stream_name }
  end

  def broadcast_initial_chat_title
    if chat.title.blank? && chat.messages.where(role: "user").order(:id).pick(:id) == id
      broadcast_safely { chat.broadcast_title }
    end
  end

  def broadcast_safely
    yield
  rescue => error
    # Delivery is best-effort; a Cable outage must not prevent a saved reply.
    Rails.error.report(error, context: {message_id: id, chat_id: chat_id})
  end
end
