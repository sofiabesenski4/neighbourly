require "csv"

module ContentPipeline
  module Parsers
    # Parses a CSV whose columns are not known ahead of time. Each row becomes
    # one document. Every header/value pair is kept in metadata so the row can
    # be reinterpreted later, and the content is a plain "Header: value"
    # rendering so the document is searchable before any LLM summary exists.
    class Csv < Base
      ID_HEADER = /\Aid\z/i
      # "name" or "title" as a whole word, so "Program Name" and "job_title"
      # match but "Filename" and "Username" do not.
      TITLE_HEADER = /(?:\A|[^a-z])(?:name|title)(?:[^a-z]|\z)/i
      MAX_TITLE_LENGTH = 120

      # Column names that hold a row's address, compared after lowercasing
      # and turning anything but letters into single spaces, so "Street
      # Address", "street_address" and "STREET-ADDRESS" all match.
      # The resource and its service both take their address from these.
      ADDRESS_HEADERS = {
        street_address: ["address", "street address", "street", "address line", "address line 1", "address 1"],
        city: ["city", "town", "municipality"],
        province: ["province", "state", "province or state", "state or province", "prov"],
        postal_code: ["postal code", "postcode", "postal", "zip", "zip code"],
        country: ["country"],
        phone: ["phone", "phone number", "telephone"],
        lat: ["lat", "latitude"],
        lng: ["lng", "lon", "long", "longitude"]
      }.freeze

      # Columns naming who offers the service, compared the same way.
      ORGANIZATION_HEADERS = ["organization", "organisation", "organization name", "organisation name", "org",
        "agency", "agency name", "provider", "provider name", "operator", "operated by", "run by"].freeze

      # Columns that fill in the service's own fields, compared the same way.
      # The first filled-in match wins. Every other column with a value, apart
      # from the address, is kept in the service's additional details under its
      # own header.
      SERVICE_HEADERS = {
        description: ["description", "service description", "services", "about", "summary"],
        hours: ["hours", "hours of operation", "opening hours", "schedule"],
        phone: ADDRESS_HEADERS[:phone] + ["tel"],
        email: ["email", "e mail", "email address"],
        website: ["website", "web site", "web", "url", "site"]
      }.freeze

      # One "Header: value" line per filled-in cell. Enrichment keeps these
      # lines under the summary so exact details stay searchable.
      def self.render_fields(fields)
        fields.filter_map { |header, value| "#{header}: #{value}" if value.present? }.join("\n")
      end

      # "Street Address", "street_address" and "STREET-ADDRESS" all become
      # "street address". Digits stay, so "Address Line 1" and "Address Line 2"
      # remain different columns.
      def self.header_key(header)
        header.downcase.gsub(/[^a-z0-9]+/, " ").strip
      end

      FIELD_HEADERS = (SERVICE_HEADERS.values.flatten + ADDRESS_HEADERS.values.flatten + ORGANIZATION_HEADERS).to_set.freeze

      # True for a column that fills a service, address or organization field,
      # like "Schedule" for hours. A row can have two such columns, and only
      # the first fills the field, so the other is kept in additional details.
      # A repeated header, renamed "Phone (2)", counts as the one it repeats.
      def self.field_header?(header)
        FIELD_HEADERS.include?(header_key(header.to_s.sub(/ \(\d+\)\z/, "")))
      end

      def parse(raw_content)
        table = CSV.parse(normalize_encoding(raw_content), headers: true)
        headers = unique_headers(table.headers)

        chunks = table.filter_map do |row|
          fields = row_fields(headers, row.fields)
          next if fields.values.all?(&:nil?)

          title_header, title, named = title_for(fields)
          id_header, external_id = external_id_for(fields)
          organization_header, organization = first_match(fields, ORGANIZATION_HEADERS)
          address, address_headers = address_for(fields)
          {
            title: title,
            content: self.class.render_fields(fields),
            external_id: external_id,
            categories: [],
            metadata: fields,
            address: address,
            # A service is only named from a name or title column. Without
            # one, the row's first value is no name, so enrichment names it.
            service: service_for(fields, (title if named), used: [(title_header if named), id_header, organization_header, *address_headers]),
            organization: organization && {name: organization}
          }
        end

        # Rows sharing an external_id would upsert the same document, so keep
        # the last one, which is the one that ends up stored.
        chunks.index_by { |chunk| chunk[:external_id] }.values
      rescue CSV::MalformedCSVError => e
        raise ParseError, "could not be read as CSV: #{e.message}"
      end

      private

      # Uploads arrive as binary. Spreadsheet exports are often UTF-8 with a
      # byte order mark, or Windows-1252 when saved from Excel.
      def normalize_encoding(raw_content)
        text = raw_content.dup.force_encoding(Encoding::UTF_8)
        text = text.encode(Encoding::UTF_8, Encoding::Windows_1252, invalid: :replace, undef: :replace) unless text.valid_encoding?
        text.delete_prefix("﻿")
      end

      # Blank headers get a positional name and repeated headers get a suffix,
      # so no column's value is overwritten in metadata. Every header written
      # in the file is reserved first, so a generated name never takes one.
      def unique_headers(raw_headers)
        written = raw_headers.map { |header| header.to_s.strip.presence }
        taken = Set.new(written.compact)
        kept = Set.new

        written.each_with_index.map do |name, index|
          if name && kept.add?(name)
            name
          else
            free_name(name || "column_#{index + 1}", taken)
          end
        end
      end

      # A row with more cells than headers keeps its extra cells under
      # positional names instead of dropping them.
      def row_fields(headers, values)
        taken = Set.new(headers)
        extras = (headers.size...values.size).map { |index| free_name("column_#{index + 1}", taken) }
        (headers + extras).each_with_index.to_h { |name, index| [name, values[index].to_s.strip.presence] }
      end

      # Returns base, or base with the lowest free " (n)" suffix, and marks it taken.
      def free_name(base, taken)
        name = base
        suffix = 1
        name = "#{base} (#{suffix += 1})" while taken.include?(name)
        taken << name
        name
      end

      # The column the title came from, the title, and whether that column
      # names the row. A row with no name or title column takes its first
      # value as the title. "Organization Name" is who runs the service, not
      # its name, so it is never the title.
      def title_for(fields)
        header, value = fields.find do |name, text|
          name.match?(TITLE_HEADER) && text.present? && !ORGANIZATION_HEADERS.include?(self.class.header_key(name))
        end
        named = header.present?
        header, value = fields.find { |_name, text| text.present? } unless named
        [header, value.truncate(MAX_TITLE_LENGTH), named]
      end

      # The service's fields from the columns that match them, and every other
      # filled-in column in additional details. Columns already used for the
      # title, ID or organization are left out of the details.
      def service_for(fields, title, used:)
        used = used.compact.to_set
        service = {name: title}
        # A row can give several phone columns, like "Phone" and "Phone
        # Number". All of them go on the service's phone, so an admin who
        # clears it clears every number the row gave. Printouts put each on
        # its own line.
        phones = all_matches(fields, SERVICE_HEADERS[:phone])
        if phones.any?
          service[:phone] = phones.map(&:last).uniq.join(", ")
          used.merge(phones.map(&:first))
        end
        SERVICE_HEADERS.except(:phone).each do |attribute, names|
          header, value = first_match(fields, names)
          next if header.nil?

          # A website that isn't a web address stays in the details as written.
          value = web_address(value) if attribute == :website
          next if value.nil?

          service[attribute] = value
          used << header
        end
        service[:additional_details] = fields.reject { |header, value| value.blank? || used.include?(header) }
        service
      end

      # The first filled-in column, in the order of names, as [header, value].
      def first_match(fields, names)
        by_key = fields.each_with_object({}) do |(header, value), found|
          found[self.class.header_key(header)] ||= [header, value] if value.present?
        end
        names.lazy.filter_map { |name| by_key[name] }.first
      end

      # Every filled-in column matching one of the names, in the row's order.
      # A repeated header, which unique_headers renamed to "Phone (2)",
      # matches as the header it repeats.
      def all_matches(fields, names)
        fields.select { |header, value|
          value.present? && names.include?(self.class.header_key(header.sub(/ \(\d+\)\z/, "")))
        }.to_a
      end

      # The first filled-in column for each part of the address, and the
      # columns used, so those aren't kept again in the service's additional
      # details. Enrichment fills in parts the columns don't give.
      def address_for(fields)
        matches = ADDRESS_HEADERS.transform_values { |names| first_match(fields, names) }
        [matches.transform_values { |match| match&.last }, matches.values.compact.map(&:first)]
      end

      # The ID column and its value, or a hash of the row when it has none.
      def external_id_for(fields)
        header, id = fields.find { |name, value| name.match?(ID_HEADER) && value.present? }
        header ? [header, id] : [nil, Digest::SHA256.hexdigest(fields.to_json)]
      end
    end
  end
end
