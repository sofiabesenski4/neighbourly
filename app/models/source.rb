class Source < ApplicationRecord
  has_many :documents, dependent: :destroy

  validates :name, presence: true
  validates :url, presence: true, unless: -> { form? || api? || csv? }
  validates :url, uniqueness: true, if: -> { url.present? }
  validates :source_type, presence: true, inclusion: {in: %w[api html form csv]}

  # Uploads are ingested by IngestSourceJob. Form entries are never ingested
  # and have no status.
  enum :ingestion_status,
    {pending: "pending", ingesting: "ingesting", succeeded: "succeeded", failed: "failed"},
    prefix: :ingestion, validate: {allow_nil: true}

  scope :api_sources, -> { where(source_type: "api") }
  scope :html_sources, -> { where(source_type: "html") }
  scope :form_sources, -> { where(source_type: "form") }
  scope :csv_sources, -> { where(source_type: "csv") }
  # Sources the pipeline can re-fetch: a parsed type with an origin URL.
  # Form entries and URL-less uploads have nothing to fetch.
  scope :fetchable, -> { where(source_type: %w[api html csv]).where.not(url: [nil, ""]) }

  def api?
    source_type == "api"
  end

  def html?
    source_type == "html"
  end

  def form?
    source_type == "form"
  end

  def csv?
    source_type == "csv"
  end

  def self.form_entry_source
    find_or_create_by!(source_type: "form") do |s|
      s.name = "Form Entries"
    end
  end
end
