# The allowlist of saved resource information used by both HTML and PDF cards.
# Missing values remove the complete field, including its label. These values
# are never supplemented with model-generated information.
class ResourceCard
  CONTENT_LABELS = ["City", "Address", "Phone", "Email", "Website", "Hours",
    "Age range", "Gender", "Categories", "Description", "Notes", "Intake", "Beds"].freeze

  attr_reader :document

  def initialize(document)
    @document = document
  end

  def title
    text(document.title) || "Resource"
  end

  def fields
    address = value("address", "Address")
    city = value("city", "City")
    rows = [
      ["Services", value("description", "Description") || value("categories", "Categories")],
      ["Address", address && [address, city].compact.join(", ")],
      ["City", (city unless address)],
      ["Hours", value("hours", "Hours")],
      ["Phone", value("phone", "Phone", separator: "\n")],
      ["Email", value("email", "Email")],
      ["Website", value("website", "Website")],
      ["Ages served", ages],
      ["Eligibility", value("gender", "Gender")],
      ["Languages", value("language_services")],
      ["Notes", value("notes", "Notes")],
      ["Intake", value("intake_info", "Intake")],
      ["Last updated", value("last_updated_at") || value("last_updated")],
      ["Information source", value("source_url") || text(document.source&.url)]
    ]
    rows.filter_map { |label, content| {label: label, value: content} if content }
  end

  def as_json(*)
    {id: document.id, title: title, fields: fields}
  end

  private

  def value(key, legacy_label = nil, separator: ", ")
    text(document.metadata[key], separator: separator) || (text(content_fields[legacy_label], separator: separator) if legacy_label)
  end

  def text(value, separator: ", ")
    case value
    when nil, Hash then nil
    when Array then value.filter_map { |item| text(item) }.join(separator).presence
    else value.to_s.strip.presence
    end
  end

  def ages
    range = document.metadata["age_range"]
    if range.is_a?(Hash)
      minimum, maximum = text(range["min"]), text(range["max"])
      return "#{minimum}-#{maximum}" if minimum && maximum
      return "#{minimum}+" if minimum
      return "Up to #{maximum}" if maximum
    end
    value("age_range_text", "Age range")
  end

  # Older imports kept Notes and Intake only in the searchable text. Read the
  # importer's labelled fields deterministically so those records retain all
  # their information without a fresh scrape, import, or LLM call.
  def content_fields
    @content_fields ||= document.content.to_s
      .split(/\n(?=(?:#{CONTENT_LABELS.map { |label| Regexp.escape(label) }.join("|")}):)/)
      .filter_map { |part|
        label, content = part.split(":", 2)
        [label, content] if CONTENT_LABELS.include?(label) && content
      }.to_h
  end
end
