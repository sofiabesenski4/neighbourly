class SourcesController < ApplicationController
  before_action :authenticate_user!

  def index
    authorize Source
    @sources = policy_scope(Source).where.not(source_type: "form").order(created_at: :desc)
    @documents = Document.joins(:source).where(sources: {source_type: "form"}).order(created_at: :desc)
  end

  def show
    @source = Source.find(params[:id])
    authorize @source
    @documents = @source.documents.order(title: :asc)
  end

  def new
    authorize Source
    @source = Source.new
  end

  def create
    authorize Source
    @source = Source.new(source_params.except(:file))

    file = source_params[:file]
    unless file.present?
      @source.errors.add(:file, "must be provided")
      render :new, status: :unprocessable_entity and return
    end

    unless valid_file_type?(file, @source.source_type)
      @source.errors.add(:file, "must be a .json file for API sources or an .html file for HTML sources")
      render :new, status: :unprocessable_entity and return
    end

    if @source.save
      raw_content = file.read
      count = ContentPipeline::Ingester.new(@source).ingest(raw_content)
      redirect_to sources_path, notice: "Source '#{@source.name}' created and #{count} documents ingested."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @source = Source.find(params[:id])
    authorize @source
    @source.destroy!
    redirect_to sources_path, notice: "Source '#{@source.name}' was deleted.", status: :see_other
  end

  private

  def source_params
    params.require(:source).permit(:name, :url, :source_type, :css_selector, :file)
  end

  def valid_file_type?(file, source_type)
    extension = File.extname(file.original_filename).downcase
    case source_type
    when "api" then extension == ".json"
    when "html" then extension.in?([".html", ".htm"])
    else false
    end
  end
end
