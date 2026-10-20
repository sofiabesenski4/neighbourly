class FlyersController < ApplicationController
  # Flyers are open to anonymous users so outreach workers and neighbours can
  # print one without an account. Building a PDF will not be cheap, so keep a
  # per-IP ceiling that a shared library or shelter connection won't hit.
  rate_limit to: 30, within: 1.hour,
    by: -> { request.remote_ip },
    with: -> { rate_limit_exceeded("We've made a lot of flyers for this connection. Please try again later.") },
    only: :create

  def new
    @flyer = Flyer.new
  end

  def create
    @flyer = Flyer.new(flyer_params)

    unless @flyer.valid?
      render :new, status: :unprocessable_content
      return
    end

    pdf = FlyerGenerator.call(categories: @flyer.categories)

    if pdf.present?
      send_data pdf, filename: "neighbourly-flyer.pdf", type: "application/pdf", disposition: "inline"
    else
      redirect_to new_flyer_path, notice: "Flyer generation is coming soon. Your selection was received."
    end
  end

  private

  def flyer_params
    params.fetch(:flyer, {}).permit(categories: [])
  end
end
