module ContentPipeline
  module Parsers
    # Parses HTML pages using Nokogiri. Extracts text content from a
    # configurable CSS selector (or the full <body> by default), then
    # splits it into overlapping chunks suitable for embedding.
    class Html < Base
      MAX_CHUNK_LENGTH = 1500 # characters (~375 tokens)
      OVERLAP_LENGTH = 200  # characters of overlap between chunks

      def parse(raw_content)
        doc = Nokogiri::HTML(raw_content)

        # Remove non-content elements
        doc.css("script, style, nav, footer, header, noscript, iframe").remove

        # Extract text from targeted selector or full body
        container = if @source.css_selector.present?
          doc.css(@source.css_selector)
        else
          doc.css("body")
        end

        text = extract_text(container)
        return [] if text.blank?

        page_title = doc.at_css("title")&.text&.strip || @source.name

        Chunker.call(text).each_with_index.map do |chunk, index|
          {
            title: page_title,
            content: chunk,
            external_id: "#{Digest::SHA256.hexdigest(@source.url)}_#{index}",
            metadata: {
              url: @source.url,
              chunk_index: index,
              page_title: page_title
            }
          }
        end
      end

      private

      def extract_text(nodes)
        nodes.map do |node|
          format_tables(node)
          node.text
            .gsub(/[ \t]+/, " ")
            .gsub(/\n{3,}/, "\n\n")
            .strip
        end.join("\n\n").strip
      end

      def format_tables(node)
        node.css("table").each do |table|
          headers = table.css("thead th").map { |th| th.text.strip }

          rows = table.css("tbody tr, tr").map do |tr|
            cells = tr.css("td").map { |td| td.text.strip }
            next if cells.empty?

            if headers.any? && headers.length == cells.length
              headers.zip(cells).map { |h, c| "#{h}: #{c}" }.join(" | ")
            else
              cells.join(" | ")
            end
          end.compact

          table.replace(rows.join("\n"))
        end
      end
    end
  end
end
