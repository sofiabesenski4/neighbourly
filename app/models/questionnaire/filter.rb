# What every questionnaire filter can do. A filter turns the answer to one question into
# part of the search.
#
# Architecture: Questionnaire builds a filter for each answered question, merges their search
# options into one CategorySearch.call, and passes the filters along for keep? and rank. A
# new kind of question subclasses this and is registered in Questionnaire::FILTERS.
#
# A filter for something CategorySearch takes as an argument, like categories, overrides
# search_options. One for something in a service's details, like ages, overrides keep? or
# rank, and reads the details through ResourceAttributes.
class Questionnaire
  class Filter
    # The options worth offering. A filter overrides this when some can't be searched for.
    def self.available(options)
      options
    end

    # The names of the CategorySearch arguments that search_options sets. Two questions can't
    # set the same one, and Questionnaire checks that when it loads the config.
    def self.search_keys
      []
    end

    # The answer's value: for most questions, the options the person chose. Never empty,
    # because an unanswered question has no filter.
    def initialize(options)
      @options = options
    end

    # Arguments for CategorySearch.call.
    def search_options
      {}
    end

    # False only when known details rule the service out. Unknown ones must not.
    def keep?(service)
      true
    end

    # Where the service comes among the others. Lower comes first, and nothing is hidden.
    def rank(service)
      0
    end

    private

    attr_reader :options
  end
end
