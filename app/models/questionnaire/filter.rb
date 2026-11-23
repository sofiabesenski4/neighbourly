# What every questionnaire filter can do. A filter turns the answer to one question into
# part of the search.
#
# Architecture: Questionnaire builds a filter for each answered question and merges their
# search options into one CategorySearch.call. A new kind of question subclasses this and
# is registered in Questionnaire::FILTERS.
class Questionnaire
  class Filter
    # The options worth offering. A filter overrides this when some can't be searched for.
    def self.available(options)
      options
    end

    # The options the person chose. Never empty: an unanswered question has no filter.
    def initialize(options)
      @options = options
    end

    # Arguments for CategorySearch.call.
    def search_options
      {}
    end

    private

    attr_reader :options
  end
end
