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

      private

      # A website as a link, adding https:// to a bare domain like
      # "example.org". Nil for anything that isn't a web address, which the
      # caller keeps in the service's additional details instead.
      def web_address(value)
        text = value.to_s.strip
        return if text.empty?
        # The same check services and organizations validate with, so a value
        # kept here never stops the service from saving.
        return text if ApplicationRecord.web_address?(text)

        link = "https://#{text}"
        link if text.match?(/\A[a-z0-9-]+(\.[a-z0-9-]+)+(\/\S*)?\z/i) && ApplicationRecord.web_address?(link)
      end
    end
  end
end
