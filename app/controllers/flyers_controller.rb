class FlyersController < ApplicationController
  # A direct visit applies this document's PDF policy. Active guest chats can
  # switch to Printout within their existing document, which permits blob frames.
  content_security_policy do |policy|
    policy.frame_src :blob
    policy.object_src :blob
  end

  before_action :reject_malformed_selection

  # Flyers are open to anonymous users so outreach workers and neighbours can
  # print one without an account. Building a PDF will not be cheap, so keep a
  # per-IP ceiling that a shared library or shelter connection won't hit.
  rate_limit to: 30, within: 1.hour, name: "create",
    by: -> { request.remote_ip },
    with: -> { rate_limit_exceeded("We've made a lot of flyers for this connection. Please try again later.") },
    only: :create

  # Allow ten live previews per printable guide without consuming the PDF quota.
  rate_limit to: 300, within: 1.hour, name: "preview",
    by: -> { request.remote_ip },
    with: -> { render json: {errors: ["We've looked up a lot of resources for this connection. Please try again later."]}, status: :too_many_requests },
    only: :preview, if: -> { request.format.json? }

  def new
    @flyer = Flyer.new(flyer_params)
    return if @flyer.valid?

    render :new, status: :unprocessable_content
  end

  def preview
    @flyer = Flyer.new(flyer_params)
    unless @flyer.valid?
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: {errors: @flyer.errors.full_messages}, status: :unprocessable_content }
      end
      return
    end

    if request.format.html?
      destination = @flyer.categories.empty? ? new_flyer_path : new_flyer_path(flyer: {categories: @flyer.categories})
      redirect_to destination
      return
    end

    @sections = CategorySearch.call(categories: @flyer.categories)
    respond_to do |format|
      format.json do
        render json: {categories: @sections.map { |section|
          {key: section.category&.id&.to_s, name: section.name,
           resources: section.resources.map { |resource| ResourceCard.new(resource).as_json }}
        }}
      end
    end
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed => error
    Rails.error.report(error, context: {feature: "category_preview", categories: @flyer&.categories})
    message = "We couldn't load those resources. Please try again."
    respond_to do |format|
      format.html do
        @flyer ||= Flyer.new
        @flyer.errors.add(:base, message)
        render :new, status: :service_unavailable
      end
      format.json { render json: {errors: [message]}, status: :service_unavailable }
    end
  end

  def create
    @flyer = Flyer.new(flyer_params)

    unless @flyer.valid?
      if request.format.pdf?
        render json: {errors: @flyer.errors.full_messages}, status: :unprocessable_content
      else
        render :new, status: :unprocessable_content
      end
      return
    end

    pdf = FlyerGenerator.call(categories: @flyer.categories)

    if pdf.present?
      send_data pdf, filename: "neighbourly-flyer.pdf", type: "application/pdf", disposition: "inline"
    else
      message = if @flyer.categories.empty?
        "No resources are available to print."
      else
        "No resources matched those categories. Try another selection."
      end
      if request.format.pdf?
        render json: {errors: [message]}, status: :not_found
      else
        redirect_to new_flyer_path, notice: message
      end
    end
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed => error
    Rails.error.report(error, context: {feature: "category_flyer", categories: @flyer&.categories})
    message = "We couldn't create the flyer. Please try again."
    if request.format.pdf?
      render json: {errors: [message]}, status: :service_unavailable
    else
      redirect_to new_flyer_path, alert: message
    end
  end

  private

  # A malformed filter is an error, rather than an instruction to show all.
  def reject_malformed_selection
    return unless params.key?(:flyer)

    input = params[:flyer]
    unexpected = input.is_a?(ActionController::Parameters) ? input.keys - ["categories"] : []
    valid = input.is_a?(ActionController::Parameters) &&
      unexpected.empty? &&
      (input[:categories].nil? || (input[:categories].is_a?(Array) && input[:categories].all? { |value| value.is_a?(String) }))
    return if valid

    @flyer = Flyer.new
    if unexpected.any?
      @flyer.errors.add(:base, "Unsupported flyer filters: #{unexpected.join(", ")}")
    else
      @flyer.errors.add(:categories, "must be provided as a list")
    end
    if request.format.json? || request.format.pdf?
      render json: {errors: @flyer.errors.full_messages}, status: :unprocessable_content
    else
      render :new, status: :unprocessable_content
    end
  end

  def flyer_params
    flyer = params.fetch(:flyer, {})
    flyer.is_a?(ActionController::Parameters) ? flyer.permit(categories: []) : {}
  end
end
