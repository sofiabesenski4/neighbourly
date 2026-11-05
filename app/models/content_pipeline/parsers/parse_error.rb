module ContentPipeline
  module Parsers
    # Raised when uploaded content cannot be read in the expected format.
    class ParseError < StandardError; end
  end
end
