class Report < ApplicationRecord
  belongs_to :document
  belongs_to :user, optional: true

  REASONS = ["out of date", "offensive", "false information", "unclear", "other"].freeze
  STATUSES = %w[pending valid dismissed].freeze

  validates :reason, presence: true, inclusion: {in: REASONS}
  validates :status, presence: true, inclusion: {in: STATUSES}

  scope :pending, -> { where(status: "pending") }
  scope :most_recent, -> { order(created_at: :desc) }
  scope :awaiting_digest, -> { where(digest_sent: false) }

  def pending?
    status == "pending"
  end

  def valid_report?
    status == "valid"
  end

  def dismissed?
    status == "dismissed"
  end
end
