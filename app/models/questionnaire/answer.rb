# What was chosen for one question, and whether what was submitted made sense.
#
# Architecture: Question#read builds one from a submitted value. `options` is empty both for
# a skipped question, which is valid, and for an answer that couldn't be understood.
class Questionnaire
  Answer = Data.define(:options, :valid) do
    def valid?
      valid
    end
  end
end
