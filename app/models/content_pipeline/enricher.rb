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
    TEXT

    def initialize(document, model: nil)
      @document = document
      @model = model || ENV["ENRICHMENT_MODEL"].presence || RubyLLM.config.default_model
    end

    # Returns false without saving when the row changed while the model was
    # answering, since the summary would describe the old row.
    def enrich!
      metadata = @document.metadata
      result = describe(metadata)

      @document.with_lock do
        if @document.metadata == metadata
          @document.title = result[:title] if result[:title]
          @document.content = [result[:summary], Parsers::Csv.render_fields(metadata)].join("\n\n")
          @document.enriched_at = Time.current
          @document.save_with_category_names!(result[:categories])
        else
          false
        end
      end
    end

    private

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
            categories: {type: "array", items: category}
          },
          required: %w[title summary categories],
          additionalProperties: false
        }
      }
    end

    # Models without structured output may wrap the JSON in prose or a code
    # fence, so read the outermost object. Category names are matched to the
    # real list and anything else is dropped.
    def parse(content, categories)
      data = content.is_a?(Hash) ? content.stringify_keys : JSON.parse(content.to_s[/\{.*\}/m].to_s)
      summary = data["summary"].to_s.strip
      raise InvalidResponse, "The model returned no summary." if summary.blank?

      by_name = categories.index_by(&:downcase)
      {
        title: data["title"].to_s.squish.presence&.truncate(Parsers::Csv::MAX_TITLE_LENGTH),
        summary: summary.truncate(MAX_SUMMARY_LENGTH),
        categories: Array(data["categories"]).filter_map { |name| by_name[name.to_s.strip.downcase] }.uniq
      }
    rescue JSON::ParserError
      raise InvalidResponse, "The model did not return JSON."
    end
  end
end
