# What a service's details say about who it's for, as values that can be compared.
#
# Architecture: questionnaire filters use this to decide whether a service suits someone.
# It's the only questionnaire code that reads `additional_details`. ResourceCard reads the
# same details to show them, and finds them by the same names, but shows whatever was saved.
#
# Each method returns nil when the value is missing or unclear, and never guesses from free
# text. Callers must treat nil as "unknown", which never rules a service out. Someone missing
# a service they could use is worse than someone seeing one they can't.
#
# docs/service-details.md lists the names and formats that are found, for anyone saving
# services. A detail under any other name is unknown here, with no error.
#
# Add a method here, and to NAMES, for each new kind of detail a question needs. The formats
# below are the ones saved today, and an agreed format may replace them. See
# docs/questionnaire-notes.md.
class ResourceAttributes
  # The details a question can require. A name in the config is looked up here, so it can only
  # ever call these. Add each new method's name.
  NAMES = {"age_range" => :age_range}.freeze

  # Where ages may be saved, best first. ResourceCard shows the first of these too.
  AGE_HEADERS = ["age range", "ages", "age"].freeze

  # Whether any service that people can see has a clear value for one of NAMES. Stops at the
  # first that does, so it's only slow when none has, and each is read in turn.
  def self.any_known?(name)
    attribute = NAMES.fetch(name)
    Service.visible.select(:id, :additional_details).find_each.any? { |service| !new(service).public_send(attribute).nil? }
  end

  # "15-25" or "15 to 25", and "19+".
  AGES_BETWEEN = /\A(\d{1,3})\s*(?:-|–|to)\s*(\d{1,3})\z/
  AGES_FROM = /\A(\d{1,3})\s*\+\z/
  private_constant :AGES_BETWEEN, :AGES_FROM

  def initialize(service)
    @details = service.details_by_header
  end

  # The ages served, like 15..25, or 19.. with no upper limit.
  #
  # Uses the first of these details that's filled in, the same one the card shows. If that
  # one is unclear the answer is nil, even when another is clear, because they disagree.
  def age_range
    value = @details.values_at(*AGE_HEADERS).find { |detail| filled_in?(detail) }
    value.is_a?(Hash) ? range_from_form(value) : range_from_text(value)
  end

  private

  # The resource form saves {"min" => 19, "max" => nil}, with both nil when left blank.
  def filled_in?(detail)
    detail.is_a?(Hash) ? detail.values_at("min", "max").any?(&:present?) : detail.present?
  end

  def range_from_form(value)
    minimum, maximum = value.values_at("min", "max").map(&:presence)
    range(minimum, maximum)
  end

  def range_from_text(value)
    text = value.to_s.strip
    if (match = text.match(AGES_BETWEEN))
      range(match[1], match[2])
    elsif (match = text.match(AGES_FROM))
      range(match[1], nil)
    end
  end

  # Either end can be open, but one that's there must be a whole number. Base 10 so that
  # "08" isn't read as octal.
  def range(minimum, maximum)
    first, last = [minimum, maximum].map { |age| age && Integer(age.to_s, 10, exception: false) }
    return if (minimum && first.nil?) || (maximum && last.nil?)

    first ||= 0
    (first..last) if first >= 0 && (last.nil? || first <= last)
  end
end
