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
end
