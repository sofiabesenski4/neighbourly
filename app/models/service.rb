# One thing people can go to for help, like a meal program or a shelter, and
# how to reach it. It is offered by an organization when the data says which.
#
# Details with no column of their own, such as eligibility, languages or
# intake steps, are kept in `additional_details`, so nothing a source gives is lost.
#
# A service keeps a record of where its details came from: the source, and the
# imported row (Document) when there is one. A service added by an admin
# belongs to the form entries source and has no row.
#
# Chat and printouts still read documents. They move to services in a later
# phase of NEI-34.
class Service < ApplicationRecord
  include Locatable

  # The BC Address Geocoder only knows BC, so it would match an address
  # elsewhere to the wrong place. These are the values that mean BC and Canada.
  BC_NAMES = ["bc", "b.c.", "british columbia"].freeze
  CANADA_NAMES = ["ca", "can", "canada"].freeze

  belongs_to :organization, optional: true
  belongs_to :source
  belongs_to :document, optional: true
  has_and_belongs_to_many :categories, -> { order(:name) }

  # Data from the United States says "state".
  alias_attribute :state, :province

  normalizes :name, with: ->(name) { name.squish }
  normalizes :description, :hours, :phone, :email, :website, :address_line,
    :city, :province, :postal_code, :country, with: ->(value) { value.strip.presence }
  normalizes :additional_details, with: ->(details) { details || {} }, apply_to_nil: true

  validates :name, presence: true
  validates :document_id, uniqueness: true, allow_nil: true
  validate :additional_details_is_an_object
  validates :website, format: {with: %r{\Ahttps?://}i, message: "must start with http:// or https://"}, allow_nil: true

  scope :alphabetical, -> { order(Arel.sql("LOWER(services.name)"), :id) }

  def category_names
    categories.map(&:name)
  end

  # The text to send to the geocoder, like "919 Pandora Ave, Victoria, BC", or
  # nil when this can't be looked up. A city alone gets no query, because that
  # could only match the middle of town.
  def geocoding_query
    street = address_line.to_s.strip
    [street, city.presence, "BC"].compact.join(", ") if street.present? && in_bc?
  end

  # A missing province or country is taken to be BC, Canada, where every
  # service so far is.
  def in_bc?
    (province.nil? || BC_NAMES.include?(province.downcase)) &&
      (country.nil? || CANADA_NAMES.include?(country.downcase))
  end

  private

  def additional_details_is_an_object
    errors.add(:additional_details, "must be a set of named values") unless additional_details.is_a?(Hash)
  end

  def awaiting_enrichment?
    document.present? && document.awaiting_enrichment?
  end

  def location_attributes
    %w[address_line city province country]
  end
end
