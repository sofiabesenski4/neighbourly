module ContentPipeline
  # Asks a model to fill in what a service left blank, using only the
  # service's own details: its fields, address, organization and additional
  # details, which for an import hold every column of the row. What the
  # service already says always wins, so the model can't overwrite a source's
  # facts or a person's edits. Its name is filled only when it has none.
  #
  # Facts with no field of their own, like who is eligible or how to get in,
  # go in additional details under a fixed set of names that printouts read.
  #
  # It also writes enriched_description, a plain-language description of the
  # service, and embeds it. That is how chat finds the service, including one
  # added on the site with no imported row.
  class Enricher
    class InvalidResponse < StandardError; end

    MAX_SUMMARY_LENGTH = 2_000

    # The details enrichment may add, each with the names a source might
    # already use for it. A service that has any of those keeps its own.
    DETAILS = {
      "eligibility" => ["eligibility", "gender"],
      "ages" => ["ages", "age", "age range"],
      "languages" => ["languages", "language", "language services"],
      "intake" => ["intake", "intake info"],
      "cost" => ["cost", "fee", "fees", "price"]
    }.freeze

    ADDRESS_FIELDS = %i[street_address city province postal_code].freeze
    TEXT_FIELDS = %i[hours phone email].freeze

    INSTRUCTIONS = <<~TEXT
      You fill in the gaps in one community service's details. People use them to find help, on printouts and in a chatbot.
      Use only facts in the given details. Never guess names, hours, eligibility, locations or contact details. Leave a field empty when the details don't say.
      name: the name of the service, in a few words.
      summary: two to four plain sentences describing the service by name: what is offered, who it is for, and where and when. Base it mostly on the service's own description, adding what its other details, organization and additional details say.
      categories: every category from the given list that the service clearly fits, spelled exactly as listed. Leave it empty if none fit.
      street_address: where people go, such as "919 Pandora Ave", or a corner such as "Douglas St and Yates St", exactly as given.
      city, province, postal_code: of that address, exactly as given.
      hours: when it is open, exactly as given.
      phone: the phone number to call, exactly as given.
      email: the email address to write to.
      website: the service's web address.
      organization: the name of the organization that runs the service.
      eligibility: who can use it, such as "Women and children" or "Youth in care".
      ages: the ages it serves, such as "19+" or "12-18".
      languages: the languages it is offered in.
      intake: how to get the service, such as "Walk in" or "Referral from a social worker".
      cost: what it costs, such as "Free".
    TEXT

    def initialize(service, model: nil)
      @service = service
      @model = model || ENV["ENRICHMENT_MODEL"].presence || RubyLLM.config.default_model
    end

    # Returns false without saving when the service changed while the model
    # was answering, such as a re-import or someone's edit. The answer fits
    # the old details, so a fresh run is queued for the new ones.
    def enrich!
      asked = facts(@service)
      result = describe(asked)
      # Embedded here rather than on save, so a rate limit or outage raises
      # its own error and the job retries it.
      embedding = Embedder.embed(result[:summary])

      address_queued_by_save = false
      saved = @service.with_lock do
        # Locking reloads the service, so this sees any change made meanwhile.
        next false unless @service.awaiting_enrichment? && facts(@service) == asked

        fill_in(result)
        @service.enriched_description = result[:summary]
        @service.embedding = embedding
        address = @service.address
        address_queued_by_save = address.present? && (address.street_address_changed? || address.city_changed?)
        @service.enriched_at = Time.current
        @service.save!
        true
      end

      if saved
        # The address waited for enrichment before its lookup. It may not have
        # moved, so queue the lookup here when saving didn't.
        @service.address&.locate_later unless address_queued_by_save
      elsif @service.awaiting_enrichment?
        EnrichServiceJob.perform_later(@service)
      end
      saved
    rescue ActiveRecord::RecordNotFound
      # The service was deleted while the model was answering.
      false
    end

    private

    # What the model is told, and what must still hold when its answer lands.
    def facts(service)
      address = service.address&.attributes&.slice("street_address", "city", "province", "postal_code", "country")
      {
        name: service.name,
        description: service.description,
        hours: service.hours,
        phone: service.phone,
        email: service.email,
        website: service.website,
        address: address&.compact,
        organization: service.organization&.name,
        categories: service.category_names,
        additional_details: service.additional_details
      }.compact_blank
    end

    # Blank fields only. The organization is linked only when there is none,
    # and categories only when the service has none. The description stays as
    # its source or a person wrote it.
    def fill_in(result)
      # A nameless import falls back to its row's title, its first value. A
      # service added on the site has no row, so a reply that doesn't name it
      # can't be used, and the job asks again.
      @service.name ||= result[:name] || @service.document&.title
      raise InvalidResponse, "The model returned no name." if @service.name.nil?

      TEXT_FIELDS.each { |field| @service[field] = result[field] if @service[field].blank? && result[field] }
      @service.website ||= web_address(result[:website])
      fill_in_address(result.slice(*ADDRESS_FIELDS).compact)
      @service.organization ||= Organization.for_name(result[:organization], source: @service.source)
      @service.categories = Category.where(name: result[:categories]) if @service.categories.empty? && result[:categories].any?
      fill_in_details(result[:details])
    end

    # Filling in a blank city or province doesn't move the address, so
    # coordinates it already has, such as from its import, are kept.
    def fill_in_address(found)
      address = @service.address
      blanks = found.select { |field, _value| address.nil? || address.public_send(field).blank? }
      return if blanks.empty?

      (address || @service.build_address).assign_attributes(blanks)
      return unless address&.coordinates

      address.lat_will_change!
      address.lng_will_change!
    end

    def fill_in_details(found)
      present = @service.additional_details
        .reject { |_key, value| value.blank? && value != false }
        .keys.map { |key| Parsers::Csv.header_key(key.to_s) }
      added = found.reject { |key, value| value.nil? || DETAILS.fetch(key).intersect?(present) }
      @service.additional_details = @service.additional_details.merge(added) if added.any?
    end

    # A model may give a bare domain like "example.org". Only something that
    # is, or becomes with https://, a whole web address is kept.
    def web_address(value)
      return if value.nil?

      candidate = value.match?(%r{\Ahttps?://}i) ? value : "https://#{value}"
      candidate if ApplicationRecord.web_address?(candidate)
    end

    def describe(asked)
      categories = Category.order(:name).pluck(:name)
      response = RubyLLM.chat(model: @model)
        .with_instructions(INSTRUCTIONS)
        .with_schema(schema(categories))
        .ask("Categories: #{categories.to_json}\nService: #{asked.to_json}")

      parse(response.content, categories)
    end

    TEXT_PROPERTIES = (%w[name summary street_address city province postal_code hours phone email website organization] + DETAILS.keys).freeze

    def schema(categories)
      category = {type: "string"}
      category[:enum] = categories if categories.any?

      {
        name: "service_enrichment",
        schema: {
          type: "object",
          properties: TEXT_PROPERTIES.index_with { {type: "string"} }.merge("categories" => {type: "array", items: category}),
          required: TEXT_PROPERTIES + ["categories"],
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

      by_name = categories.index_by(&:downcase)
      {
        name: text_in(data["name"])&.truncate(Parsers::Csv::MAX_TITLE_LENGTH),
        summary: summary.truncate(MAX_SUMMARY_LENGTH),
        categories: Array(data["categories"]).filter_map { |name| by_name[name.to_s.strip.downcase] }.uniq,
        organization: text_in(data["organization"]),
        website: text_in(data["website"]),
        details: DETAILS.keys.index_with { |key| text_in(data[key]) }
      }.merge((ADDRESS_FIELDS + TEXT_FIELDS).index_with { |field| text_in(data[field.to_s]) })
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
