module ContentPipeline
  module Parsers
    # Base class for content parsers.
    # Subclasses must implement #parse, which yields hashes with
    # :title, :content, :external_id, and :metadata keys. They may also
    # give :address, a hash of the keyword arguments Document#assign_address
    # takes, which is saved on the resource's address.
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
