# The allowlist of saved resource information used by both HTML and PDF cards.
# Missing values remove the complete field, including its label. These values
# are never supplemented with model-generated information.
class ResourceCard
  CONTENT_LABELS = ["City", "Address", "Phone", "Email", "Website", "Hours",
    "Age range", "Gender", "Categories", "Description", "Notes", "Intake", "Beds"].freeze

  # Assumes about 5 km/h, a common estimate for walking. Many people using these
  # guides may be slower, which is why the printout calls this an estimate.
  WALKING_MINUTES_PER_KM = 12

  # How much further someone walks than the straight line between two places, because
  # they follow streets. On a grid, a trip along one street is 1.0 and a diagonal one is
  # about 1.41, so 1.3 sits near a typical trip. It's an estimate that hasn't been measured
  # against Victoria's streets, and it doesn't cover detours around water. See
  # docs/resource-map-notes.md.
  STREET_ROUTE_FACTOR = 1.3

  attr_reader :document

  # The origin is optional. The preview and printout pass the same one, so they show
  # the same distances. Without it, or when the resource's location isn't known, the
  # card simply has no Distance row, like any other missing field.
  def initialize(document, origin: nil)
    @document = document
    @origin = origin
  end

  def title
    text(document.title) || "Resource"
  end

  def fields
    location = document.location
    address = text(location.street_address) || text(content_fields["Address"])
    city = text(content_fields["City"]) || text(location.city)
    # Several numbers are saved as one comma-separated value. Each gets a line.
    phone = text(location.phone&.split(/,\s*/), separator: "\n") || text(content_fields["Phone"])
    rows = [
      ["Services", value("description", "Description") || text(document.category_names)],
      ["Address", address && [address, city].compact.join(", ")],
      ["City", (city unless address)],
      ["Distance", distance],
      ["Hours", value("hours", "Hours")],
      ["Phone", phone],
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

  def distance_km
    point = document.coordinates if @origin&.located?
    @origin.point.distance_km_to(point) if point
  end

  private

  # Like "1.0 km straight-line, about 16 min walk". Calculated from saved coordinates
  # with no network call. The distance is labelled straight-line because that's what it
  # measures, while the time allows for following streets.
  def distance
    km = distance_km
    return unless km

    length = (km < 0.1) ? "Under 0.1 km" : "#{format("%.1f", km)} km"
    "#{length} straight-line, about #{walking_time(km)} walk"
  end

  def walking_time(km)
    minutes = [(km * STREET_ROUTE_FACTOR * WALKING_MINUTES_PER_KM).round, 1].max
    return "#{minutes} min" if minutes < 60

    hours, leftover = minutes.divmod(60)
    leftover.zero? ? "#{hours} hr" : "#{hours} hr #{leftover} min"
  end

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
