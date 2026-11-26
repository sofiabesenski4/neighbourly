# A detail of a service that a changed import row would replace. The service
# keeps its current value until an admin approves the row's value or rejects
# it, so an admin's edit or an enrichment fill isn't lost to a re-import
# without someone choosing which to keep.
#
# A detail that is blank on the service, or that the row gives unchanged, is
# not a conflict: the import writes it straight away.
class ImportConflict < ApplicationRecord
  STATUSES = %w[pending approved rejected].freeze
  # Categories are left out: enrichment sets them from the row again anyway.
  FIELDS = %w[name description hours phone email website closed additional_details organization address].freeze
  LOCATION_FIELDS = %w[street_address city province postal_code country].freeze
  LABELS = {"additional_details" => "Additional details", "closed" => "Open or closed"}.freeze

  belongs_to :service
  belongs_to :decided_by, class_name: "User", optional: true

  validates :status, inclusion: {in: STATUSES}
  validates :field, inclusion: {in: FIELDS}

  scope :pending, -> { where(status: "pending") }
  # In the order the service's details are shown.
  scope :in_field_order, -> { in_order_of(:field, FIELDS) }

  # The service's value for one detail now: text, true or false, a set of
  # named values, or for the address its location fields.
  def self.value_on(service, field)
    case field.to_s
    when "organization" then service.organization&.name
    when "address" then location(service.address&.attributes || {})
    else service.public_send(field)
    end
  end

  # Sets one detail on the service, without saving it.
  def self.assign(service, field, value)
    case field.to_s
    when "organization"
      # A service stays with its organization while the row names it by any
      # name it has had, even if another organization now uses an old one.
      service.organization = Organization.for_name(value, source: service.source) unless service.organization&.goes_by?(value)
    when "address"
      assign_address(service, value || {})
    else
      service.public_send(:"#{field}=", value)
    end
  end

  # True when the service has no value for the detail, or the row gives the
  # same one, so the row's value can be written without asking.
  def self.writable?(service, field, value)
    return true if field.to_s == "organization" && service.organization&.goes_by?(value)

    current = comparable(field, value_on(service, field))
    current.blank? || current == comparable(field, value)
  end

  def self.label(field)
    LABELS.fetch(field.to_s) { field.to_s.humanize }
  end

  # Values as the record would store them, so " 250-555-0100 " and
  # "250-555-0100" aren't taken for a change.
  def self.comparable(field, value)
    case field.to_s
    when "organization" then Organization.normalize_name(value)
    when "address" then location(value || {})
    when "closed" then ActiveModel::Type::Boolean.new.cast(value) || false
    when "additional_details" then (value || {}).to_h.stringify_keys.compact_blank
    else Service.normalize_value_for(field, value)
    end
  end

  # The location fields of an address, without blanks or coordinates.
  def self.location(fields)
    fields = fields.to_h.stringify_keys
    LOCATION_FIELDS.index_with { |name| Address.normalize_value_for(name, fields[name]) }.compact
  end

  # Coordinates come with the row's address, so a lookup already made for it
  # is kept. A service with no address and no location to give gets none.
  def self.assign_address(service, value)
    value = value.to_h.stringify_keys
    location = location(value)
    coordinates = value.slice("lat", "lng").compact_blank
    return if service.address.nil? && location.empty? && coordinates.empty?

    cleared = LOCATION_FIELDS.index_with(nil)
    (service.address || service.build_address).assign_attributes(cleared.merge(location).merge(coordinates))
  end
  private_class_method :assign_address

  def pending?
    status == "pending"
  end

  def label
    self.class.label(field)
  end

  def current_value
    self.class.value_on(service, field)
  end

  # Writes the row's value to the service. Returns false when someone else
  # decided first, or a later import replaced this conflict.
  def approve!(user)
    decide!("approved", user) do
      self.class.assign(service, field, incoming_value)
      service.save!
    end
  end

  # Keeps the service's current value.
  def reject!(user)
    decide!("rejected", user)
  end

  private

  # Imports and enrichment lock the row the service was read from while they
  # write it, so the decision takes the same lock.
  def decide!(decision, user)
    (service.document || service).with_lock do
      reload
      if pending?
        yield if block_given?
        update!(status: decision, decided_by: user, decided_at: Time.current)
        true
      else
        false
      end
    end
  end
end
