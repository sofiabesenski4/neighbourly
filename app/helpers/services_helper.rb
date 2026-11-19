module ServicesHelper
  # One extra detail as text. A plain list reads as "a, b, c". Nested values
  # are shown as indented JSON, so nothing is hidden.
  def service_detail_text(value)
    case value
    when Hash then JSON.pretty_generate(value)
    when Array
      nested = value.any? { |item| item.is_a?(Hash) || item.is_a?(Array) }
      nested ? JSON.pretty_generate(value) : value.join(", ")
    else value.to_s
    end
  end
end
