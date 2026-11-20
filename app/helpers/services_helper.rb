module ServicesHelper
  SORT_LABELS = {"name" => "name", "organization" => "organization", "city" => "city", "updated" => "last updated", "confirmed" => "last confirmed"}.freeze

  def sort_label(column)
    SORT_LABELS.fetch(column, "name")
  end

  # A header link that sorts the services table by its column. Clicking the
  # column it is already sorted by reverses the order.
  def service_sort_link(label, column)
    current = @sort == column
    direction = (current && @direction == "asc") ? "desc" : "asc"
    arrow = {"asc" => " ↑", "desc" => " ↓"}.fetch(@direction) if current
    link_to "#{label}#{arrow}", services_path(sort: column, direction: direction),
      class: "admin-link", aria: {label: "Sort by #{sort_label(column)}, #{(direction == "asc") ? "ascending" : "descending"}"}
  end

  def service_sort_state(column)
    return "none" unless @sort == column

    (@direction == "asc") ? "ascending" : "descending"
  end

  # One extra detail as text. true and false read as "Yes" and "No", and a
  # plain list as "a, b, c". Nested values are shown as indented JSON, so
  # nothing is hidden.
  def service_detail_text(value)
    case value
    when true then "Yes"
    when false then "No"
    when Hash then JSON.pretty_generate(value)
    when Array
      nested = value.any? { |item| item.is_a?(Hash) || item.is_a?(Array) }
      nested ? JSON.pretty_generate(value) : value.join(", ")
    else value.to_s
    end
  end
end
