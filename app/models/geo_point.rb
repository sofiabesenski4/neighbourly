# A single location on Earth: a latitude and longitude in decimal degrees, using
# the same coordinate system as GPS and web maps (WGS 84). Victoria is roughly
# lat 48.43, lng -123.37.
#
# This is the shared way the app passes a location around. Geocoder returns one
# after looking up an address, and Document#coordinates builds one from a
# resource's saved metadata. Using named fields rather than a [lat, lng] array
# means no calling code has to remember which number comes first. That matters
# here because the geocoder's own replies list longitude first.
class GeoPoint < Data.define(:lat, :lng)
  EARTH_RADIUS_KM = 6371.0

  # The straight-line distance to another point, along the Earth's surface, using
  # the haversine formula. It knows nothing about streets or water, so the real
  # route is longer, sometimes by a lot around the Inner Harbour.
  def distance_km_to(other)
    lat_change = radians(other.lat - lat)
    lng_change = radians(other.lng - lng)
    a = Math.sin(lat_change / 2)**2 +
      Math.cos(radians(lat)) * Math.cos(radians(other.lat)) * Math.sin(lng_change / 2)**2
    2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(a))
  end

  private

  def radians(degrees)
    degrees * Math::PI / 180
  end
end
