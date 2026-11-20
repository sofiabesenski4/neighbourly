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
  has_and_belongs_to_many :categories, -> { order(:name) }
  # Where it is, coordinates included, lives on its address.
  has_one :address, as: :addressable, dependent: :destroy, autosave: true
  # Blank location fields add no address, but can clear one already there.
  accepts_nested_attributes_for :address,
    reject_if: ->(fields) { fields["id"].blank? && fields.except("id").values.all?(&:blank?) }

  normalizes :name, with: ->(name) { name.squish }
  normalizes :description, :hours, :phone, :email, :website, with: ->(value) { value.strip.presence }
  normalizes :additional_details, with: ->(details) { details || {} }, apply_to_nil: true

  validates :name, presence: true
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
    "updated" => "services.updated_at"
  }.freeze

  # Sorted by one of SORTS, then by name. Anything unknown sorts by name.
  def self.sorted_by(column, direction)
    expression = SORTS.fetch(column.to_s, SORTS["name"])
    direction = (direction.to_s == "desc") ? "DESC" : "ASC"
    left_joins(:organization, :address)
      .order(Arel.sql("#{expression} #{direction} NULLS LAST"), Arel.sql("LOWER(services.name)"), :id)
  end

  def category_names
    categories.map(&:name)
  end

  # A GeoPoint, or nil when there is no address or its location isn't known.
  def coordinates
    address&.coordinates
  end

  private

  def additional_details_is_an_object
    errors.add(:additional_details, "must be a set of named values") unless additional_details.is_a?(Hash)
  end
end
