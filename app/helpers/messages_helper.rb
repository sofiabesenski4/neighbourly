module MessagesHelper
  def reference_source_url(source)
    uri = URI.parse(source.url.to_s)
    uri.to_s if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  # One reference in a reply's list. key is what citations use: "s12" for a
  # service, "12" for a row. A report needs a row, so a service added on the
  # site, which has none, can't be reported from chat.
  Reference = Data.define(:key, :title, :source, :text, :report_document)

  # Services first, then rows, each in the order chat found them.
  def message_references(message)
    services = message.rag_services.map do |service|
      Reference.new(key: "s#{service.id}", title: service.display_name, source: service.source,
        text: [service.enriched_description, service.description].compact_blank.uniq.join("\n\n"),
        report_document: service.document)
    end
    documents = message.rag_documents.map do |document|
      Reference.new(key: document.id.to_s, title: reference_title(document), source: document.source,
        text: document.content, report_document: document)
    end
    services + documents
  end

  # A reference read into a service goes by the service's current name, so it
  # matches what printouts and admins call it.
  def reference_title(document)
    document.service&.name.presence || document.title.presence || "Untitled reference"
  end

  def tool_result_partial(message)
    name = message.respond_to?(:parent_tool_call) ? message.parent_tool_call&.name.to_s : ""
    partial_for(prefix: "messages/tool_results", name: name)
  end

  def tool_call_partial(tool_call)
    partial_for(prefix: "messages/tool_calls", name: tool_call.name.to_s)
  end

  private

  def partial_for(prefix:, name:)
    normalized = name.to_s.underscore.tr("-", "_")
    if normalized.present? && lookup_context.exists?(normalized, [prefix], true)
      "#{prefix}/#{normalized}"
    else
      "#{prefix}/default"
    end
  end
end
