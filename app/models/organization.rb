# A group that offers services, like a society, charity or health authority.
# Admins see which services each one runs. Imports link services to the
# organization a row names, matching it by name.
class Organization < ApplicationRecord
  include HasWebsite

  belongs_to :source, optional: true
  # Removing an organization keeps its services, unlinked.
  has_many :services, dependent: :nullify
  has_one :address, as: :addressable, dependent: :destroy, autosave: true
  # Blank location fields add no address, but can clear one already there.
  accepts_nested_attributes_for :address,
    reject_if: ->(fields) { fields["id"].blank? && fields.except("id").values.all?(&:blank?) }

  normalizes :name, with: ->(name) { name.squish }
  normalizes :description, :website, :email, :phone, with: ->(value) { value.strip.presence }

  before_validation { self.normalized_name = self.class.normalize_name(name) }

  validates :name, presence: true
  validate :name_not_taken

  scope :alphabetical, -> { order(:normalized_name) }

  # "Our Place Society", "our place society" and " Our  Place Society " are
  # one organization.
  def self.normalize_name(name)
    name.to_s.squish.downcase.presence
  end

  # The organization with this name, created as first seen in the source when
  # there is none yet. Nil for a blank name. Imports call this for each row,
  # so two rows naming one organization share it.
  def self.for_name(name, source: nil)
    normalized = normalize_name(name)
    return if normalized.nil?

    find_by(normalized_name: normalized) ||
      # A savepoint, so a clash with a concurrent import doesn't abort the
      # import's own transaction.
      transaction(requires_new: true) { create!(name: name, source: source) }
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by!(normalized_name: normalized)
  end

  private

  def name_not_taken
    return if normalized_name.nil?

    taken = Organization.where(normalized_name: normalized_name).where.not(id: id).exists?
    errors.add(:name, "is already used by another organization") if taken
  end
end
