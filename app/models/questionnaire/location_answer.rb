# The place someone typed, and where it is once that's been looked up.
#
# Architecture: Question#read builds one from a submitted value. Pressing Next on the
# question calls #resolve, which looks the place up through FlyerOrigin. Its text and
# coordinates then travel in hidden fields, so later screens don't look it up again.
#
# - `text`: what they typed, or nil for a skipped question.
# - `point`: where it is, as a GeoPoint. Nil until it's looked up, or if that failed.
# - `checked`: whether `text` has been looked up. With no point, the address service was
#   down, and the person carries on without distances.
# - `problem`: why the answer can't be used, or nil.
#
# Privacy: this may be someone's home. Coordinates are rounded to 3 decimals, about 100 m,
# and nothing is saved.
class Questionnaire
  LocationAnswer = Data.define(:text, :point, :checked, :problem) do
    def initialize(text: nil, point: nil, checked: false, problem: nil)
      super
    end

    # Reads the form's fields: `near`, what they typed, and from a place already looked up,
    # `checked`, the text it was for, with `lat` and `lng`.
    #
    # The coordinates only count while the text is the one they're for. Typing another place
    # makes them out of date, and it's looked up afresh.
    def self.read(submitted)
      return new if submitted.nil?
      return new(problem: :unreadable) unless submitted.is_a?(Hash) && submitted.values.all?(String)

      text = submitted["near"].to_s.strip.presence
      return new if text.nil?
      return new(text: text, problem: :too_long) if text.length > self::LIMIT
      return new(text: text) unless submitted["checked"] == text

      # Flyer already knows which submitted coordinates are usable, and rounds them.
      new(text: text, point: Flyer.new(lat: submitted["lat"], lng: submitted["lng"]).coordinates, checked: true)
    end

    def valid?
      problem.nil?
    end

    def answered?
      text.present?
    end

    def located?
      point.present?
    end

    # What LocationFilter is built with. An origin with no point means the same here as it
    # does to printouts: the place is known only by name.
    def value
      FlyerOrigin.new(label: text, point: point)
    end

    def fields
      return [] unless answered?

      [["[near]", text], *lookup_fields]
    end

    # The fields from the lookup, without what was typed. The question's own page has a text
    # box for that. A lookup that failed is left out there, so pressing Next tries again.
    def lookup_fields
      return [] unless checked

      [["[checked]", text], *([["[lat]", point.lat], ["[lng]", point.lng]] if located?)]
    end

    def lookup_needed?
      valid? && answered? && !checked
    end

    # Looks the place up, unless that's been done. Without `lookup`, because this connection
    # has had too many, it's treated as if the address service were down.
    def resolve(lookup: true)
      return self unless lookup_needed?
      return with(checked: true) unless lookup

      origin = FlyerOrigin.locate(text)
      return with(problem: :not_found) if origin.nil?

      with(checked: true, point: origin.point && rounded(origin.point))
    end

    private

    def rounded(point)
      GeoPoint.new(lat: point.lat.round(3), lng: point.lng.round(3))
    end
  end

  # As long as the printout allows.
  LocationAnswer::LIMIT = 200
end
