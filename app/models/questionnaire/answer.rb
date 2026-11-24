# What was chosen for a checkboxes or radio question, and whether what was submitted made
# sense.
#
# Architecture: Question#read builds one from a submitted value. `options` is empty both for
# a skipped question, which is valid, and for an answer that couldn't be understood.
#
# LocationAnswer is the same for a location question. Both respond to everything below, so
# Questionnaire and the views needn't know which they have.
class Questionnaire
  Answer = Data.define(:options, :valid) do
    def valid?
      valid
    end

    # Why it isn't valid, for choosing what to tell the person. Nil when it is.
    def problem
      :unreadable unless valid
    end

    # False for a skipped question, which gets no filter.
    def answered?
      options.any?
    end

    # What the question's filter is built with.
    def value
      options
    end

    # The hidden fields that carry this answer to other screens. Each is the end of the
    # field's name, and its value.
    def fields
      options.map { |option| ["[]", option.key] }
    end

    # Whether #resolve would call an outside service.
    def lookup_needed?
      false
    end

    # Does any lookup the answer needs, and returns the answer with its result.
    def resolve(lookup: true)
      self
    end
  end
end
