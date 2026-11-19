# A website that links to a real web address. Admins see it as a link, so a
# value without an http or https scheme and a host is refused.
module HasWebsite
  extend ActiveSupport::Concern

  included do
    validate :website_is_a_web_address
  end

  private

  def website_is_a_web_address
    return if website.nil? || ApplicationRecord.web_address?(website)

    errors.add(:website, "must be a web address starting with http:// or https://")
  end
end
