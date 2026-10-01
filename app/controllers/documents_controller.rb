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

    if @document.save
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

    if @document.save
      redirect_to @document, notice: "Resource '#{@document.title}' was updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @document
    title = @document.title
    @document.destroy!
    redirect_back fallback_location: sources_path, notice: "Resource '#{title}' was deleted.", status: :see_other
  end

  private

  def set_document
    @document = Document.find(params[:id])
  end

  def document_params
    params.require(:document).permit(
      :title, :description, :city, :address, :phone, :email,
      :website, :hours, :categories, :age_min, :age_max, :gender, :notes
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
    parts << "Categories: #{p[:categories]}" if p[:categories].present?
    parts << "Description: #{p[:description]}" if p[:description].present?
    parts << "Notes: #{p[:notes]}" if p[:notes].present?
    parts.join("\n")
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
    meta[:categories] = p[:categories].split(",").map(&:strip).reject(&:blank?) if p[:categories].present?
    meta[:description] = p[:description] if p[:description].present?
    meta[:notes] = p[:notes] if p[:notes].present?
    meta
  end
end
