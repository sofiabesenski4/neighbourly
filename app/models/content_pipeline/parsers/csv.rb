require "csv"

module ContentPipeline
  module Parsers
    # Parses a CSV whose columns are not known ahead of time. Each row becomes
    # one document. Every header/value pair is kept in metadata so the row can
    # be reinterpreted later, and the content is a plain "Header: value"
    # rendering so the document is searchable before any LLM summary exists.
    class Csv < Base
      ID_HEADER = /\Aid\z/i
      TITLE_HEADER = /name|title/i
      MAX_TITLE_LENGTH = 120

      def parse(raw_content)
        table = CSV.parse(normalize_encoding(raw_content), headers: true)
        headers = unique_headers(table.headers)

        chunks = table.filter_map do |row|
          fields = row_fields(headers, row.fields)
          next if fields.values.all?(&:nil?)

          {
            title: title_for(fields),
            content: content_for(fields),
            external_id: external_id_for(fields),
            categories: [],
            metadata: fields
          }
        end

        # Rows sharing an external_id would upsert the same document, so keep
        # the last one, which is the one that ends up stored.
        chunks.index_by { |chunk| chunk[:external_id] }.values
      end

      private

      # Uploads arrive as binary, so read them as UTF-8.
      def normalize_encoding(raw_content)
        raw_content.dup.force_encoding(Encoding::UTF_8)
      end

      def unique_headers(raw_headers)
        raw_headers.map { |header| header.to_s.strip }
      end

      def row_fields(headers, values)
        headers.each_with_index.to_h { |name, index| [name, values[index].to_s.strip.presence] }
      end

      def title_for(fields)
        named = fields.find { |header, value| header.match?(TITLE_HEADER) && value.present? }&.last
        (named || fields.values.compact.first).truncate(MAX_TITLE_LENGTH)
      end

      def content_for(fields)
        fields.filter_map { |header, value| "#{header}: #{value}" if value }.join("\n")
      end

      def external_id_for(fields)
        id = fields.find { |header, value| header.match?(ID_HEADER) && value.present? }&.last
        id || Digest::SHA256.hexdigest(fields.to_json)
      end
    end
  end
end
