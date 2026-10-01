module ContentPipeline
  module Parsers
    # Parses structured JSON data (e.g. BC 211 shelter listings).
    # Each JSON object becomes a single document chunk with its key
    # fields concatenated into searchable text and structured data
    # preserved in metadata.
    class Api < Base
      def parse(raw_content)
        records = JSON.parse(raw_content)
        records = [records] unless records.is_a?(Array)

        records.filter_map do |record|
          next if record["post_title"].blank?

          {
            title: record["post_title"],
            content: build_content(record),
            external_id: record["id"]&.to_s || record["ID"]&.to_s,
            metadata: build_metadata(record)
          }
        end
      end

      private

      def build_content(record)
        location = hash_field(record, "location")
        beds = hash_field(record, "beds")
        age_range = hash_field(record, "age_range")

        parts = []
        parts << record["post_title"]

        city_label = location&.dig("city", "label")
        parts << "City: #{city_label}" if city_label.present?

        address = location&.dig("street_address")
        parts << "Address: #{address}" if address.present?

        contacts = Array(record["contact"]).filter_map { |c| c.dig("contact", "phone_number") }.reject(&:blank?)
        parts << "Phone: #{contacts.join(", ")}" if contacts.any?

        availability = beds&.dig("availability")
        parts << "Beds: #{availability}" if availability.present?

        parts << "Currently full" if beds&.dig("full")

        age_min = age_range&.dig("min")
        age_max = age_range&.dig("max")
        if age_min.present?
          age_text = age_max.present? ? "#{age_min}-#{age_max}" : "#{age_min}+"
          parts << "Age range: #{age_text}"
        end

        genders = Array(record["gender"]).map { |g| g["label"] }.compact
        parts << "Gender: #{genders.join(", ")}" if genders.any?

        categories = Array(record["taxonomies"]).map { |t| t["name"] }.compact
        parts << "Categories: #{categories.join(", ")}" if categories.any?

        notes = record["notes"]
        parts << "Notes: #{notes}" if notes.present?

        intake = record["intake_info"]
        parts << "Intake: #{intake}" if intake.present?

        parts.join("\n")
      end

      def build_metadata(record)
        location = hash_field(record, "location")
        geo = location ? hash_field(location, "location") : nil
        beds = hash_field(record, "beds")
        age_range = hash_field(record, "age_range")

        {
          city: location&.dig("city", "value"),
          address: location&.dig("street_address"),
          lat: geo&.dig("lat"),
          lng: geo&.dig("lng"),
          phone: Array(record["contact"]).filter_map { |c| c.dig("contact", "phone_number") }.reject(&:blank?),
          beds: beds&.dig("availability"),
          full: beds&.dig("full"),
          age_range: age_range,
          gender: Array(record["gender"]).map { |g| g["value"] }.compact,
          categories: Array(record["taxonomies"]).map { |t| t["name"] }.compact,
          closed: record["closed"]
        }.compact
      end

      def hash_field(record, key)
        value = record[key]
        value.is_a?(Hash) ? value : nil
      end
    end
  end
end
