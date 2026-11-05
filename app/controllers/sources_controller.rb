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
      @source.errors.add(:file, "must be a .json file for API sources, an .html file for HTML sources, or a .csv file for CSV sources")
      render :new, status: :unprocessable_entity and return
    end

    raw_content = file.read
    # Parsing is quick next to embedding, so a malformed file is caught here
    # and shown on the form instead of failing later in the background.
    ContentPipeline::Ingester.new(@source).parse(raw_content)

    @source.assign_attributes(upload_content: raw_content, ingestion_status: :pending)
    if @source.save
      if enqueue_ingestion(@source)
        redirect_to @source, notice: "Source '#{@source.name}' created. Its documents are being ingested in the background."
      else
        redirect_to @source, alert: "Source '#{@source.name}' was created, but its ingestion could not be started."
      end
    else
      render :new, status: :unprocessable_entity
    end
  rescue ContentPipeline::Parsers::ParseError => e
    @source.errors.add(:file, e.message)
    render :new, status: :unprocessable_entity
  end

  def destroy
    @source = Source.find(params[:id])
    authorize @source
    @source.destroy!
    redirect_to sources_path, notice: "Source '#{@source.name}' was deleted.", status: :see_other
  end

  private

  # A source whose job was never queued would wait forever, so record the
  # failure where the admin can see it. The upload is kept for a retry.
  def enqueue_ingestion(source)
    return true if IngestSourceJob.perform_later(source)

    source.update!(ingestion_status: :failed, ingestion_error: "Ingestion could not be queued.")
    false
  rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError => e
    Rails.error.report(e, context: {source_id: source.id})
    source.update!(ingestion_status: :failed, ingestion_error: "Ingestion could not be queued: #{e.message}")
    false
  end

  def source_params
    params.require(:source).permit(:name, :url, :source_type, :css_selector, :file)
  end

  def valid_file_type?(file, source_type)
    extension = File.extname(file.original_filename).downcase
    case source_type
    when "api" then extension == ".json"
    when "html" then extension.in?([".html", ".htm"])
    when "csv" then extension == ".csv"
    else false
    end
  end
end
