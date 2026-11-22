class FlyersController < ApplicationController
  # The printout opens in its own tab rather than in a frame on this page, so this
  # screen keeps the app-wide policy that blocks all embedded content.

  before_action :prevent_preview_caching, only: [:from_questionnaire, :preview], if: -> { request.post? }
  before_action :reject_malformed_selection

  # Flyers are open to anonymous users so outreach workers and neighbours can
  # print one without an account. Building a PDF will not be cheap, so keep a
  # per-IP ceiling that a shared library or shelter connection won't hit.
  rate_limit to: 30, within: 1.hour, name: "create",
    by: -> { request.remote_ip },
    with: -> { rate_limit_exceeded("We've made a lot of flyers for this connection. Please try again later.") },
    only: :create

  # Each check calls the geocoder for an anonymous visitor, so this also stops the site
  # being used as a free way into that service. It allows for corrections per printout.
  rate_limit to: 60, within: 1.hour, name: "locate",
    by: -> { request.remote_ip },
    with: -> { render json: {errors: ["We've checked a lot of places for this connection. Please try again later."]}, status: :too_many_requests },
    only: :locate

  # Allow ten live previews per printable guide without consuming the PDF quota.
  rate_limit to: 300, within: 1.hour, name: "preview",
    by: -> { request.remote_ip },
    with: -> { render json: {errors: ["We've looked up a lot of resources for this connection. Please try again later."]}, status: :too_many_requests },
    only: :preview, if: -> { request.format.json? }

  def new
    @flyer = Flyer.new({detail_level: "summary"}.merge(flyer_params.to_h.symbolize_keys))
    return if @flyer.valid?

    render :new, status: :unprocessable_content
  end

  def from_questionnaire
    @flyer = Flyer.new(flyer_params.slice(:categories, :query, :sort, :lat, :lng).merge(detail_level: "summary"))
    unless @flyer.valid?
      render :new, status: :unprocessable_content
      return
    end

    if (point = @flyer.coordinates)
      @flyer.lat = point.lat
      @flyer.lng = point.lng
    end
    @from_questionnaire = true
    render :new
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
      filters = @flyer.filters.compact_blank
      destination = filters.empty? ? new_flyer_path : new_flyer_path(flyer: filters)
      redirect_to destination
      return
    end

    origin = coordinates_origin
    @sections = CategorySearch.call(**@flyer.filters, origin: origin)
    respond_to do |format|
      format.json do
        palette = FlyerCategoryPalette.new(@sections.reject(&:label).map(&:name))
        render json: {categories: @sections.map { |section|
          colour = section.label ? nil : palette.colour_for(section.name)
          {key: section.category&.id&.to_s, name: section.name,
           colour: colour,
           resources: section.resources.map { |resource| ResourceCard.new(resource, origin: origin).as_json }}
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

  # Checks a typed place on the first screen, before the person chooses categories.
  # `located` is false when the geocoder is down: the place might be fine, and the page
  # lets the person carry on, because the guide can still print. Otherwise the page
  # keeps the coordinates for the preview and printout, so it needn't look up again.
  def locate
    @flyer = Flyer.new(flyer_params)
    unless @flyer.valid?
      render json: {errors: @flyer.errors.full_messages}, status: :unprocessable_content
      return
    end

    origin = @flyer.near && FlyerOrigin.locate(@flyer.near)
    if origin&.located?
      render json: {located: true, lat: origin.point.lat.round(3), lng: origin.point.lng.round(3)}
    elsif origin
      render json: {located: false}
    else
      render json: {errors: [NEAR_NOT_FOUND]}, status: :unprocessable_content
    end
  end

  def create
    @flyer = Flyer.new(flyer_params)

    unless @flyer.valid?
      render_invalid_flyer
      return
    end

    origin = printout_origin
    if @flyer.near && origin.nil?
      @flyer.errors.add(:base, NEAR_NOT_FOUND)
      render_invalid_flyer
      return
    end

    filters = @flyer.filters
    filters[:service_ids] = @flyer.service_ids if @flyer.service_ids
    pdf = FlyerGenerator.call(**filters, origin: origin, detail_level: @flyer.detail_level, site_url: root_url)

    if pdf.present?
      send_data pdf, filename: "neighbourly-flyer.pdf", type: "application/pdf", disposition: "inline"
    else
      message = if @flyer.service_ids
        "None of the selected resources are available to print. Refresh the preview and choose again."
      elsif @flyer.query.present?
        "No resources match your search."
      elsif @flyer.organizations.any?
        "No resources from those organizations match. Try another selection."
      elsif @flyer.categories.empty?
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

  def prevent_preview_caching
    response.set_header("Cache-Control", "no-store")
  end

  # Landmarks like "Central Library" and shorthand like "Douglas & Yates" don't get a
  # trustworthy match from the geocoder, so this shows the forms that do work.
  NEAR_NOT_FOUND = "We couldn't find that location. Try a street address or intersection, " \
    "like 919 Pandora Ave or Douglas St and Yates St."
  private_constant :NEAR_NOT_FOUND

  # Where the printout measures distances from, if anywhere. Coordinates are used when
  # the page has them. A typed place alone is looked up here: that's the form without
  # JavaScript, or a place the first screen couldn't check during an outage.
  def printout_origin
    coordinates_origin || (@flyer.near && FlyerOrigin.locate(@flyer.near))
  end

  # The origin from submitted coordinates, which never calls the geocoder. The preview
  # only uses this, so that changing categories can't send anything to an outside service.
  def coordinates_origin
    FlyerOrigin.from_coordinates(@flyer.coordinates, label: @flyer.near) if @flyer.coordinates
  end

  # Builder pages expect a JSON error for their PDF request. A form submitted
  # without JavaScript gets the page again, showing the errors.
  def render_invalid_flyer
    if request.format.pdf?
      render json: {errors: @flyer.errors.full_messages}, status: :unprocessable_content
    else
      render :new, status: :unprocessable_content
    end
  end

  # A malformed filter is an error, rather than an instruction to show all.
  def reject_malformed_selection
    return unless params.key?(:flyer)

    input = params[:flyer]
    supported = input.is_a?(ActionController::Parameters)
    @flyer = Flyer.new
    if supported
      list_fields = %w[categories organizations service_ids]
      text_fields = %w[query sort near lat lng detail_level]
      unexpected = input.keys - list_fields - text_fields
      @flyer.errors.add(:base, "Unsupported flyer filters: #{unexpected.join(", ")}") if unexpected.any?
      input.slice(*text_fields).each do |field, value|
        @flyer.errors.add(field, "must be text") unless value.is_a?(String)
      end
      input.slice(*list_fields).each do |field, value|
        if !value.nil? && !(value.is_a?(Array) && value.all?(String))
          @flyer.errors.add(field, "must be provided as a list")
        end
      end
    else
      @flyer.errors.add(:categories, "must be provided as a list")
    end
    return if @flyer.errors.empty?

    if request.format.json? || request.format.pdf?
      render json: {errors: @flyer.errors.full_messages}, status: :unprocessable_content
    else
      render :new, status: :unprocessable_content
    end
  end

  def flyer_params
    flyer = params.fetch(:flyer, {})
    flyer.is_a?(ActionController::Parameters) ? flyer.permit(:query, :sort, :near, :lat, :lng, :detail_level, categories: [], organizations: [], service_ids: []) : {}
  end
end
