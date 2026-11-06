# The place a printout's distances are measured from: what the person typed, plus
# where the geocoder says that is.
#
# Architecture: FlyersController calls FlyerOrigin.locate while generating a printout
# and passes the result through FlyerGenerator to FlyerPdf and ResourceCard. This is
# the one lookup that happens while printing, because we can't know the place in
# advance. Resource locations are still read from what was saved earlier.
#
# Privacy: this may be someone's home address. It's used for this one printout and
# never saved. The `near` parameter is filtered from the logs, and the error report
# below deliberately leaves the text out.
#
# FlyerOrigin.locate has three outcomes, which the controller treats differently:
# - an origin with a point: print distances from there.
# - an origin with no point: the geocoder is down. Print without distances, because
#   someone who needs a guide shouldn't be blocked by an outside service.
# - nil: the geocoder answered but found no trustworthy match. Ask the person to
#   correct it rather than printing a guide without the distances they asked for.
FlyerOrigin = Data.define(:label, :point) do
  # Whether distances can be measured from this origin.
  def located?
    point.present?
  end

  # An origin whose coordinates are already known, so nothing is sent to the geocoder.
  # They come from "Use my location", or from the first screen's check of a typed place,
  # which supplies its text as the label. The coordinates themselves aren't printed, so
  # a printout left behind doesn't show someone's exact position.
  def self.from_coordinates(point, label: nil)
    new(label: label || "your location", point: point)
  end

  def self.locate(text)
    point = Geocoder.locate(query_for(text))
    new(label: text, point: point) if point
  rescue Geocoder::Unavailable => error
    Rails.error.report(error, context: {feature: "flyer_origin"})
    new(label: text, point: nil)
  end

  # Completes what someone typed so the geocoder can score it fairly. It scores
  # a match lower when the text names no city: "919 Pandora Ave" gets 89 and would
  # be rejected, while "919 Pandora Ave, Victoria, BC" gets 100. Adding Victoria
  # still finds addresses in Saanich and Esquimalt, because the geocoder treats it
  # as another name for those areas. A comma suggests a city was already given,
  # like "500 Admirals Rd, Esquimalt", so then only the province is added.
  def self.query_for(text)
    place = text.sub(/,?\s*(BC|British Columbia)\s*\z/i, "")
    place.include?(",") ? "#{place}, BC" : "#{place}, Victoria, BC"
  end
end
