class DocumentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_document, only: [:show, :edit, :update, :destroy]
  after_action :verify_authorized

  def show
    authorize @document
  end

  def new
    authorize Document
    @document = Document.new
  end

  def create
    authorize Document

    source = Source.form_entry_source
    @document = source.documents.build(
      title: document_params[:title],
      content: build_content,
      metadata: build_metadata
    )
    if @document.save_with_category_names(selected_category_names)
      redirect_to sources_path, notice: "Resource '#{@document.title}' was created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @document
  end

  def update
    authorize @document

    @document.assign_attributes(
      title: document_params[:title],
      content: build_content,
      metadata: build_metadata
    )
    if @document.save_with_category_names(selected_category_names)
      redirect_to @document, notice: "Resource '#{@document.title}' was updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @document
    title = @document.title
    @document.destroy!
    redirect_to referer_or_default_path, notice: "Resource '#{title}' was deleted.", status: :see_other
  end

  private

  def referer_or_default_path
    return sources_path if request.referer&.match?(/\/documents\/\d+/)

    URI.parse(request.referer.to_s).path.presence || sources_path
  rescue URI::InvalidURIError
    sources_path
  end

  def set_document
    @document = Document.find(params[:id])
  end

  def document_params
    params.require(:document).permit(
      :title, :description, :city, :address, :phone, :email,
      :website, :hours, :age_min, :age_max, :gender, :notes, category_ids: []
    )
  end

  def build_content
    parts = []
    p = document_params
    parts << p[:title] if p[:title].present?
    parts << "City: #{p[:city]}" if p[:city].present?
    parts << "Address: #{p[:address]}" if p[:address].present?
    parts << "Phone: #{p[:phone]}" if p[:phone].present?
    parts << "Email: #{p[:email]}" if p[:email].present?
    parts << "Website: #{p[:website]}" if p[:website].present?
    parts << "Hours: #{p[:hours]}" if p[:hours].present?
    if p[:age_min].present?
      age_text = p[:age_max].present? ? "#{p[:age_min]}-#{p[:age_max]}" : "#{p[:age_min]}+"
      parts << "Age range: #{age_text}"
    end
    parts << "Gender: #{p[:gender]}" if p[:gender].present?
    parts << "Categories: #{selected_category_names.join(", ")}" if selected_category_names.any?
    parts << "Description: #{p[:description]}" if p[:description].present?
    parts << "Notes: #{p[:notes]}" if p[:notes].present?
    parts.join("\n")
  end

  def selected_category_names
    @selected_category_names ||= Category.where(id: Array(document_params[:category_ids]).compact_blank).order(:name).pluck(:name)
  end

  def build_metadata
    p = document_params
    meta = {}
    meta[:city] = p[:city] if p[:city].present?
    meta[:address] = p[:address] if p[:address].present?
    meta[:phone] = p[:phone].split(",").map(&:strip).reject(&:blank?) if p[:phone].present?
    meta[:email] = p[:email] if p[:email].present?
    meta[:website] = p[:website] if p[:website].present?
    meta[:hours] = p[:hours] if p[:hours].present?
    if p[:age_min].present? || p[:age_max].present?
      meta[:age_range] = {
        min: p[:age_min].presence&.to_i,
        max: p[:age_max].presence&.to_i
      }.compact
    end
    meta[:gender] = p[:gender].split(",").map(&:strip).reject(&:blank?) if p[:gender].present?
    meta[:description] = p[:description] if p[:description].present?
    meta[:notes] = p[:notes] if p[:notes].present?
    meta
  end
end
