# A single location on Earth: a latitude and longitude in decimal degrees, using
# the same coordinate system as GPS and web maps (WGS 84). Victoria is roughly
# lat 48.43, lng -123.37.
#
# This is the shared way the app passes a location around. Geocoder returns one
# after looking up an address, and Document#coordinates builds one from a
# resource's saved metadata. Using named fields rather than a [lat, lng] array
# means no calling code has to remember which number comes first. That matters
# here because the geocoder's own replies list longitude first.
GeoPoint = Data.define(:lat, :lng)
