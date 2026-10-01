class Message < ApplicationRecord
  acts_as_message
  has_many_attached :attachments
  has_many :document_messages, dependent: :destroy
  has_many :rag_documents, through: :document_messages, source: :document

  broadcasts_to ->(message) { "chat_#{message.chat_id}" }, inserts_by: :append

  def broadcast_append_chunk(content)
    broadcast_append_to "chat_#{chat_id}",
      target: "message_#{id}_content",
      content: ERB::Util.html_escape(content.to_s)
  end

  def broadcast_rag_context
    broadcast_replace_to "chat_#{chat_id}",
      target: "message_#{id}_rag_context",
      partial: "messages/rag_context",
      locals: {message: self}
  end
end
