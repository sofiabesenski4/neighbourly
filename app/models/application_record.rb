class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # A whole http or https address and nothing else. Anchored at both ends, so a
  # second line can't slip something like "javascript:" past the check.
  WEB_ADDRESS = %r{\Ahttps?://[^\s/?#@]+(?:[/?#]\S*)?\z}i

  # True for a whole http or https address that names a host. The pattern
  # alone lets "https://:443" through, which has a port but no host, so the
  # parsed address must have one too.
  def self.web_address?(value)
    value.to_s.match?(WEB_ADDRESS) && URI.parse(value.to_s).host.present?
  rescue URI::InvalidURIError
    false
  end

  # A website as a link, adding https:// to a bare domain like "example.org".
  # Nil for anything that isn't a web address, so a value kept this way never
  # stops a record with a website from saving.
  def self.web_address(value)
    text = value.to_s.strip
    return if text.empty?
    return text if web_address?(text)

    link = "https://#{text}"
    link if text.match?(/\A[a-z0-9-]+(\.[a-z0-9-]+)+(\/\S*)?\z/i) && web_address?(link)
  end
end
