# Sorts services by distance from a place, nearest first. It never hides one: services whose
# location isn't known come last.
#
# Architecture: built with the FlyerOrigin from a LocationAnswer. When the place couldn't be
# looked up it changes nothing, so services stay in name order. It mustn't ask for the
# distance sort then: without a located origin, CategorySearch falls back to grouping by
# category, which repeats services.
class Questionnaire
  class LocationFilter < Filter
    def self.search_keys
      [:origin, :sort]
    end

    def initialize(origin)
      @origin = origin
    end

    def search_options
      return {} unless @origin.located?

      {origin: @origin, sort: Flyer::DISTANCE_SORT}
    end
  end
end
