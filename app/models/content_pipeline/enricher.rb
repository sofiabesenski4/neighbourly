module ContentPipeline
  # Reads a CSV document's metadata with an LLM, then gives the document a
  # title, a plain-language summary and the categories it fits. The summary
  # sits above the row's "Header: value" lines, so the chatbot can match a
  # question asked in everyday words and still quote exact details.
  class Enricher
    class InvalidResponse < StandardError; end

    MAX_SUMMARY_LENGTH = 2_000

    INSTRUCTIONS = <<~TEXT
      You describe one row from a spreadsheet of community resources. A chatbot searches these descriptions to point people to local services.
      Use only facts in the row. Never guess hours, eligibility, locations or contact details.
      title: the name of the service or place, in a few words.
      summary: two to four plain sentences on what is offered, who it is for, and where and when, as far as the row says.
      categories: every category from the given list that the service clearly fits, spelled exactly as listed. Leave it empty if none fit.
      address: the street address where people go, such as "919 Pandora Ave", or a corner such as "Douglas St and Yates St", exactly as the row gives it. Leave it empty if the row has no street address.
      city: the city or town of that address. Leave it empty if the row does not say.
      phone: the phone number to call, exactly as the row gives it. Leave it empty if the row has none.
    TEXT

    def initialize(document, model: nil)
      @document = document
      @model = model || ENV["ENRICHMENT_MODEL"].presence || RubyLLM.config.default_model
    end

    # Returns false without saving when the row changed or was enriched by
    # another run while the model was answering. Either way this summary is
    # stale or redundant.
    def enrich!
      metadata = @document.metadata
      enriched_at = @document.enriched_at
      result = describe(metadata)
      content = [result[:summary], Parsers::Csv.render_fields(metadata)].join("\n\n")
      # Embedded here rather than on save, so a rate limit or outage raises
      # its own error and the job retries it.
      embedding = Embedder.embed(content)

      queued_by_save = false
      saved = @document.with_lock do
        # Rows geocoded before addresses had their own table may gain
        # coordinates in metadata meanwhile. Those do not change the row, so
        # the summary still fits it.
        if Document.same_row?(@document.metadata, metadata) && @document.enriched_at == enriched_at
          @document.title = result[:title] if result[:title]
          @document.content = content
          # Moderation takes the same lock to remove a resource, so a removal
          # accepted while the model was answering is seen here. The resource
          # keeps its summary but stays out of search.
          @document.embedding = @document.removal_accepted? ? nil : embedding
          # Marked changed even if equal to the old vector, so saving does not
          # embed the content a second time.
          @document.embedding_will_change!
          fill_in_address(result[:address])
          # A moved address queues its own lookup when this save commits.
          queued_by_save = @document.address.present? && (@document.address.street_address_changed? || @document.address.city_changed?)
          @document.enriched_at = Time.current
          @document.save_with_category_names!(result[:categories])
        else
          false
        end
      end

      # The row waited for enrichment before its lookup. Its address may have
      # come from its columns, unchanged by this save, so queue the lookup here.
      @document.address&.locate_later if saved && !queued_by_save
      saved
    end

    private

    # The row's own columns come first. The model only fills in what they
    # left blank, so a summary can't move a resource the file placed.
    def fill_in_address(found)
      current = @document.address
      blanks = found.select { |field, value| value && (current.nil? || current.public_send(field).blank?) }
      return if blanks.empty?

      (current || @document.build_address).assign_attributes(blanks)
    end

    def describe(metadata)
      categories = Category.order(:name).pluck(:name)
      response = RubyLLM.chat(model: @model)
        .with_instructions(INSTRUCTIONS)
        .with_schema(schema(categories))
        .ask(prompt(metadata, categories))

      parse(response.content, categories)
    end

    def prompt(metadata, categories)
      "Categories: #{categories.to_json}\nRow: #{metadata.compact.to_json}"
    end

    def schema(categories)
      category = {type: "string"}
      category[:enum] = categories if categories.any?

      {
        name: "document_enrichment",
        schema: {
          type: "object",
          properties: {
            title: {type: "string"},
            summary: {type: "string"},
            categories: {type: "array", items: category},
            address: {type: "string"},
            city: {type: "string"},
            phone: {type: "string"}
          },
          required: %w[title summary categories address city phone],
          additionalProperties: false
        }
      }
    end

    # Category names are matched to the real list and anything else is
    # dropped. Any other field that is not text is treated as missing.
    def parse(content, categories)
      data = content.is_a?(Hash) ? content.stringify_keys : json_object_in(content.to_s)
      summary = data["summary"].is_a?(String) ? data["summary"].strip : ""
      raise InvalidResponse, "The model returned no summary." if summary.blank?

      title = text_in(data["title"])
      by_name = categories.index_by(&:downcase)
      {
        title: title&.truncate(Parsers::Csv::MAX_TITLE_LENGTH),
        address: {street_address: text_in(data["address"]), city: text_in(data["city"]), phone: text_in(data["phone"])},
        summary: summary.truncate(MAX_SUMMARY_LENGTH),
        categories: Array(data["categories"]).filter_map { |name| by_name[name.to_s.strip.downcase] }.uniq
      }
    end

    def text_in(value)
      value.squish.presence if value.is_a?(String)
    end

    # Models without structured output may wrap the JSON in prose or a code
    # fence, and the prose may hold braces of its own. Return the first span
    # from a "{" to a "}" that parses as a JSON object.
    def json_object_in(text)
      closings = (0...text.length).select { |index| text[index] == "}" }.reverse
      (0...text.length).each do |opening|
        next unless text[opening] == "{"

        closings.each do |closing|
          break if closing < opening

          value = begin
            JSON.parse(text[opening..closing])
          rescue JSON::ParserError
            nil
          end
          return value if value.is_a?(Hash)
        end
      end
      raise InvalidResponse, "The model did not return JSON."
    end
  end
end
