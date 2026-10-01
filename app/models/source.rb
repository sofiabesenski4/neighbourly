class Source < ApplicationRecord
  has_many :documents, dependent: :destroy

  validates :name, presence: true
  validates :url, presence: true, unless: -> { form? || api? }
  validates :url, uniqueness: true, if: -> { url.present? }
  validates :source_type, presence: true, inclusion: {in: %w[api html form]}

  scope :api_sources, -> { where(source_type: "api") }
  scope :html_sources, -> { where(source_type: "html") }
  scope :form_sources, -> { where(source_type: "form") }

  def api?
    source_type == "api"
  end

  def html?
    source_type == "html"
  end

  def form?
    source_type == "form"
  end

  def self.form_entry_source
    find_or_create_by!(source_type: "form") do |s|
      s.name = "Form Entries"
    end
  end
end
