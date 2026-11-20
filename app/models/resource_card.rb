# The allowlist of a service's saved information used by both HTML and PDF cards.
# Missing values remove the complete field, including its label. These values
# are never supplemented with model-generated information.
class ResourceCard
  # Assumes about 5 km/h, a common estimate for walking. Many people using these
  # guides may be slower, which is why the printout calls this an estimate.
  WALKING_MINUTES_PER_KM = 12

  # How much further someone walks than the straight line between two places, because
  # they follow streets. On a grid, a trip along one street is 1.0 and a diagonal one is
  # about 1.41, so 1.3 sits near a typical trip. It's an estimate that hasn't been measured
  # against Victoria's streets, and it doesn't cover detours around water. See
  # docs/resource-map-notes.md.
  STREET_ROUTE_FACTOR = 1.3

  attr_reader :service

  # The origin is optional. The preview and printout pass the same one, so they show
  # the same distances. Without it, or when the service's location isn't known, the
  # card simply has no Distance row, like any other missing field.
  def initialize(service, origin: nil)
    @service = service
    @origin = origin
  end

  def title
    text(service.name) || "Resource"
  end

  def fields
    address = text(service.address&.street_address)
    city = text(service.address&.city)
    rows = [
      ["Services", text(service.description) || text(service.category_names)],
      ["Address", address && [address, city].compact.join(", ")],
      ["City", (city unless address)],
      ["Distance", distance],
      ["Hours", text(service.hours)],
      # Several numbers are saved as one comma-separated value. Each gets a line.
      ["Phone", text(service.phone&.split(/,\s*/), separator: "\n")],
      ["Email", text(service.email)],
      ["Website", text(service.website)],
      ["Ages served", ages],
      ["Eligibility", detail("gender", "eligibility")],
      ["Languages", detail("languages", "language", "language services")],
      ["Notes", detail("notes")],
      ["Intake", detail("intake", "intake info")],
      # Tells someone how far to trust the card, so it says when and how.
      ["Last confirmed", service.confirmation],
      ["Last updated", detail("last updated at", "last updated")],
      ["Information source", detail("source url") || text(service.source&.url)]
    ]
    rows.filter_map { |label, content| {label: label, value: content} if content }
  end

  def as_json(*)
    {id: service.id, title: title, fields: fields}
  end

  def distance_km
    point = service.coordinates if @origin&.located?
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

  def text(value, separator: ", ")
    case value
    when nil, Hash then nil
    when Array then value.filter_map { |item| text(item) }.join(separator).presence
    else value.to_s.strip.presence
    end
  end

  # The first of the named details the service has. Imports keep each column
  # under its own header, so "Intake Info", "intake_info" and "INTAKE INFO"
  # are all found as "intake info".
  def detail(*names)
    names.lazy.filter_map { |name| text(details[name]) }.first
  end

  def details
    @details ||= service.additional_details.each_with_object({}) do |(key, value), found|
      found[ContentPipeline::Parsers::Csv.header_key(key.to_s)] ||= value
    end
  end

  # The resource form saves the range as numbers. An import keeps whatever its
  # column said.
  def ages
    range = details["age range"]
    if range.is_a?(Hash)
      minimum, maximum = text(range["min"]), text(range["max"])
      return "#{minimum}-#{maximum}" if minimum && maximum
      return "#{minimum}+" if minimum
      return "Up to #{maximum}" if maximum
    end
    detail("age range", "ages", "age")
  end
end
