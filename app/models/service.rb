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
# Printouts and their map list services. Chat searches the rows, and gives
# each matched row's service by name and with its current details.
class Service < ApplicationRecord
  include HasWebsite

  belongs_to :organization, optional: true
  belongs_to :source
  belongs_to :document, optional: true
  # Who last confirmed the details were right. Removing their account keeps
  # the confirmation, without who made it.
  belongs_to :confirmed_by, class_name: "User", optional: true
  has_and_belongs_to_many :categories, -> { order(:name) }
  # Where it is, coordinates included, lives on its address.
  has_one :address, as: :addressable, dependent: :destroy, autosave: true
  # Blank location fields add no address, but can clear one already there.
  accepts_nested_attributes_for :address,
    reject_if: ->(fields) { fields["id"].blank? && fields.except("id").values.all?(&:blank?) }

  normalizes :name, with: ->(name) { name.squish }
  normalizes :description, :hours, :phone, :email, :website, with: ->(value) { value.strip.presence }
  normalizes :additional_details, with: ->(details) { details || {} }, apply_to_nil: true

  # How someone can confirm a service's details, and how printouts word it.
  CONFIRMATION_METHODS = {
    "phone" => "by phone",
    "website" => "from its website",
    "in_person" => "in person",
    "email" => "by email"
  }.freeze

  validates :name, presence: true
  validates :confirmation_method, inclusion: {in: CONFIRMATION_METHODS.keys}, allow_nil: true

  # What a confirmation vouches for. Once one of these changes, nobody has
  # checked the new value, so the confirmation no longer holds. The same rule
  # as a re-import of a changed row.
  CONFIRMED_DETAILS = %w[name description hours phone email website additional_details].freeze
  before_save :forget_confirmation, if: :confirmed_details_changed?
  validates :document_id, uniqueness: true, allow_nil: true
  validate :additional_details_is_an_object

  scope :alphabetical, -> { order(Arel.sql("LOWER(services.name)"), :id) }
  scope :in_categories, ->(category_ids) {
    where(id: Service.joins(:categories).where(categories: {id: category_ids}).select(:id))
  }
  # What printouts and chat may show. A closed service is left out, and so is
  # one whose row a moderator removed after a report.
  scope :visible, -> {
    where(closed: false)
      .where.not(id: Service.joins(document: :reports).where(reports: {status: "valid"}).select(:id))
  }

  # The columns the services table sorts by. Blank values go last either way.
  SORTS = {
    "name" => "LOWER(services.name)",
    "organization" => "LOWER(organizations.name)",
    "city" => "LOWER(addresses.city)",
    "updated" => "services.updated_at",
    "confirmed" => "services.confirmed_at"
  }.freeze

  # Sorted by one of SORTS, then by name. Anything unknown sorts by name.
  def self.sorted_by(column, direction)
    expression = SORTS.fetch(column.to_s, SORTS["name"])
    direction = (direction.to_s == "desc") ? "DESC" : "ASC"
    left_joins(:organization, :address)
      .order(Arel.sql("#{expression} #{direction} NULLS LAST"), Arel.sql("LOWER(services.name)"), :id)
  end

  # Records that someone checked the details just now, and how.
  def confirm!(by:, method:)
    update!(confirmed_at: Time.current, confirmed_by: by, confirmation_method: method)
  end

  # When and how it was last confirmed, like "Nov 20, 2026 by phone", or nil
  # when nobody has confirmed it.
  def confirmation
    return unless confirmed_at

    [confirmed_at.strftime("%b %-d, %Y"), CONFIRMATION_METHODS[confirmation_method]].compact.join(" ")
  end

  def category_names
    categories.map(&:name)
  end

  # A GeoPoint, or nil when there is no address or its location isn't known.
  def coordinates
    address&.coordinates
  end

  private

  # Confirming saves only the confirmation, which this leaves alone.
  def confirmed_details_changed?
    return false if confirmed_at.nil? || confirmed_at_changed?

    CONFIRMED_DETAILS.any? { |name| attribute_changed?(name) } || address&.changed_for_autosave? || false
  end

  def forget_confirmation
    self.confirmed_at = nil
    self.confirmed_by = nil
    self.confirmation_method = nil
  end

  def additional_details_is_an_object
    errors.add(:additional_details, "must be a set of named values") unless additional_details.is_a?(Hash)
  end
end
