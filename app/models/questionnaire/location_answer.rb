# Where someone is: a place they typed, with its location once that's been looked up, or
# their device's location.
#
# Architecture: Question#read builds one from a submitted value. Pressing Next on the
# question calls #resolve, which looks a typed place up through FlyerOrigin. The answer then
# travels in hidden fields, so later screens don't look it up again. A device's location
# arrives with its coordinates, from device_location_controller.js, and is never looked up.
#
# - `text`: what they typed. Nil for a device location or a skipped question.
# - `point`: where it is, as a GeoPoint. Nil until it's looked up, or if that failed.
# - `checked`: whether `text` has been looked up. With no point, the address service was
#   down, and the person carries on without distances.
# - `device`: whether this is the device's location.
# - `problem`: why the answer can't be used, or nil.
#
# Privacy: this may be someone's home. Coordinates are rounded to 3 decimals, about 100 m,
# and nothing is saved. The browser rounds a device's location too, so rounding it here only
# matters for a request that didn't come from our page.
class Questionnaire
  LocationAnswer = Data.define(:text, :point, :checked, :device, :problem) do
    def initialize(text: nil, point: nil, checked: false, device: false, problem: nil)
      super
    end

    # Reads the form's fields: `near`, what they typed; `lat` and `lng`; and what those
    # coordinates are for. That's the typed text in `checked`, or the device if `device` is set.
    #
    # Coordinates only count while the text is the one they're for. Typing another place makes
    # them out of date, and it's looked up afresh. Typed text also wins over the device.
    def self.read(submitted)
      return new if submitted.nil?
      return new(problem: :unreadable) unless submitted.is_a?(Hash) && submitted.values.all?(String)

      text = submitted["near"].to_s.strip.presence
      return read_device(submitted) if text.nil?
      return new(text: text, problem: :too_long) if text.length > self::LIMIT
      return new(text: text) unless submitted["checked"] == text

      new(text: text, point: point_from(submitted), checked: true)
    end

    # Nothing was typed, so this is the device's location or a skipped question.
    def self.read_device(submitted)
      return new if submitted["device"].blank?

      point = point_from(submitted)
      point ? new(point: point, checked: true, device: true) : new(problem: :device)
    end
    private_class_method :read_device

    # Flyer already knows which submitted coordinates are usable, and rounds them.
    def self.point_from(submitted)
      Flyer.new(lat: submitted["lat"], lng: submitted["lng"]).coordinates
    end
    private_class_method :point_from

    def valid?
      problem.nil?
    end

    def answered?
      device || text.present?
    end

    def located?
      point.present?
    end

    # What LocationFilter is built with. An origin with no point means the same here as it
    # does to printouts: the place is known only by name.
    def value
      device ? FlyerOrigin.from_coordinates(point) : FlyerOrigin.new(label: text, point: point)
    end

    def fields
      return [] unless answered?

      source = device ? [["[device]", "1"]] : [["[near]", text], *([["[checked]", text]] if checked)]
      source + (located? ? [["[lat]", point.lat], ["[lng]", point.lng]] : [])
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
