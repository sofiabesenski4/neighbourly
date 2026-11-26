module ContentPipeline
  module Parsers
    # Base class for content parsers.
    # Subclasses must implement #parse, which yields hashes with
    # :title, :content, :external_id, and :metadata keys. They may also give:
    #
    #   :address       the keyword arguments Document#assign_address takes,
    #                  saved on the resource's address
    #   :service       Service attributes for the service the row describes
    #   :organization  {name:} for the organization that offers it
    #
    # A web page gives no service, because its chunks are search text rather
    # than one resource each.
    class Base
      def initialize(source)
        @source = source
      end

      def parse(raw_content)
        raise NotImplementedError, "#{self.class}#parse must be implemented"
      end
    end
  end
end
