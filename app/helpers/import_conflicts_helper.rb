module ImportConflictsHelper
  # One side of a conflict as text, or "Blank" when it has no value.
  def import_conflict_value(field, value)
    text = case field
    when "address" then Address.new(value.to_h.stringify_keys.slice(*ImportConflict::LOCATION_FIELDS)).one_line
    when "closed" then ActiveModel::Type::Boolean.new.cast(value) ? "Closed" : "Open"
    when "additional_details" then value.to_h.map { |key, detail| "#{key}: #{service_detail_text(detail)}" }.join("\n")
    else service_detail_text(value)
    end
    text.presence || tag.span("Blank", class: "italic text-stone-500")
  end
end
