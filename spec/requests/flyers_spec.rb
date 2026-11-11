require "rails_helper"
require "pdf/reader"

RSpec.describe "Flyers", type: :request do
  let!(:food) { Category.create!(name: "Meals") }
  let!(:health) { Category.create!(name: "Health Care") }
  let!(:shelter) { Category.create!(name: "Shelters") }
  let!(:harm_reduction) { Category.create!(name: "Harm Reduction Resources") }

  it "uses /printout URLs and redirects old builder bookmarks with their filters" do
    expect(new_flyer_path).to eq("/printout")
    expect(flyers_path).to eq("/printout")
    expect(preview_flyers_path).to eq("/printout/preview")
    expect(locate_flyers_path).to eq("/printout/locate")

    get "/flyers/new", params: {flyer: {categories: [food.id.to_s], sort: "desc"}}
    expect(response).to redirect_to(new_flyer_path(flyer: {categories: [food.id.to_s], sort: "desc"}))
    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  describe "GET /printout" do
    it "shows every category without signing in" do
      get new_flyer_path

      expect(response).to have_http_status(:ok)
      Flyer.available_categories.each_value do |label|
        expect(response.body).to include(ERB::Util.html_escape(label))
      end
      expect(response.body).to include('data-controller="flyer-builder"', "Generate printout")
      expect(response.body).not_to include("Choose what to include. Your guide updates as you go.",
        "A resource in two selected categories appears in both sections.", "Your guide", "Live preview")
      document = Nokogiri::HTML(response.body)
      heading = document.at_css("h2#flyer-preview-heading[data-flyer-builder-target~='count']")
      expect(heading["aria-live"]).to eq("polite")
      icon = document.at_css("button[data-flyer-builder-target='generate'] svg")
      expect(icon["fill"]).to eq("none")
      expect(icon["stroke"]).to eq("currentColor")
      expect(icon["aria-hidden"]).to eq("true")
    end

    # The printout opens in its own tab, so this screen needs no exception to the
    # app-wide policy against embedded content.
    it "keeps the app-wide policy against embedded content on the builder screen" do
      get new_flyer_path

      csp = response.headers.fetch("Content-Security-Policy")
      expect(csp).to include("frame-src 'none'", "object-src 'none'", "script-src 'self'", "frame-ancestors 'none'")
      expect(csp).not_to include("blob:")
    end

    it "preserves an explicit category selection in the form" do
      get new_flyer_path, params: {flyer: {categories: [health.id.to_s]}}

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      expect(document.css('input[type="checkbox"][checked]').map { |input| input["value"] }).to eq([health.id.to_s])
    end

    it "renders an error for unknown categories while preserving recognized selections" do
      get new_flyer_path, params: {flyer: {categories: [health.id.to_s, "unknown"]}}

      expect(response).to have_http_status(:unprocessable_content)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css('[role="alert"]').text).to include("Categories include unknown options: unknown")
      expect(document.css('input[type="checkbox"][checked]').map { |input| input["value"] }).to eq([health.id.to_s])
    end

    it "starts with no categories checked and explains the unfiltered view" do
      get new_flyer_path

      document = Nokogiri::HTML(response.body)
      expect(document.css('input[type="checkbox"][checked]')).to be_empty
      expect(response.body).to include("No selection shows all available resources.")
    end
  end

  describe "POST /printout" do
    it "hands the selected categories to the generator" do
      expect(FlyerGenerator).to receive(:call).with(categories: [food.id.to_s, harm_reduction.id.to_s], origin: nil).and_return(nil)

      post flyers_path, params: {flyer: {categories: ["", food.id.to_s, harm_reduction.id.to_s]}}

      expect(response).to redirect_to(new_flyer_path)
      follow_redirect!
      expect(response.body).to include("No resources matched those categories")
    end

    it "sends the PDF when the generator produces one" do
      allow(FlyerGenerator).to receive(:call).and_return("%PDF-1.4 fake")

      post flyers_path, params: {flyer: {categories: [shelter.id.to_s]}}

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to eq("%PDF-1.4 fake")
    end

    it "prints the same matching resources in the same order as the preview" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      source = Source.create!(name: "Local", source_type: "api")
      source.documents.create!(title: "Alpha meals", content: "Meals", categories: [food, shelter])
      source.documents.create!(title: "Zebra meals", content: "Meals", categories: [shelter])
      source.documents.create!(title: "Other clinic", content: "Clinic", categories: [health])
      filters = {flyer: {query: "meals", sort: "desc"}}

      get preview_flyers_path(format: :json), params: filters
      expect(response).to have_http_status(:ok)
      names = response.parsed_body.fetch("categories").flat_map { |section| section.fetch("resources").pluck("title") }
      expect(names).to eq(["Zebra meals", "Alpha meals"])

      post flyers_path, params: filters
      expect(response).to have_http_status(:ok)
      # These cards fit on the first page; the map can repeat names in its legend.
      text = PDF::Reader.new(StringIO.new(response.body)).pages.first.text
      expect(text.scan(/(?:Zebra|Alpha) meals/)).to eq(names)
      expect(text).not_to include("Other clinic")
    end

    it "sorts the preview and PDF nearest first, placing unknown distances last" do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      source = Source.create!(name: "Local", source_type: "api")
      source.documents.create!(title: "Alpha meals", content: "Meals", categories: [food], metadata: {lat: 48.44, lng: -123.36})
      source.documents.create!(title: "Zebra meals", content: "Meals", categories: [food, shelter], metadata: {lat: 48.421, lng: -123.36})
      source.documents.create!(title: "Aardvark meals", content: "Meals", categories: [shelter])
      source.documents.create!(title: "Other clinic", content: "Clinic", categories: [health])
      filters = {flyer: {categories: [food.id.to_s, shelter.id.to_s], query: "meals", sort: "distance", lat: "48.42", lng: "-123.36"}}

      post preview_flyers_path(format: :json), params: filters
      expect(response).to have_http_status(:ok)
      names = response.parsed_body.fetch("categories").flat_map { |section| section.fetch("resources").pluck("title") }
      expect(names).to eq(["Zebra meals", "Alpha meals", "Aardvark meals"])

      post flyers_path, params: filters
      expect(response).to have_http_status(:ok)
      text = PDF::Reader.new(StringIO.new(response.body)).pages.first.text
      expect(text.scan(/(?:Zebra|Alpha|Aardvark) meals/)).to eq(names)
    end

    it "generates the unfiltered guide when nothing is selected" do
      expect(FlyerGenerator).to receive(:call).with(categories: [], origin: nil).and_return("%PDF-all")

      post flyers_path, params: {flyer: {categories: [""]}}

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("%PDF-all")
    end

    it "generates the unfiltered guide when no flyer params are sent" do
      expect(FlyerGenerator).to receive(:call).with(categories: [], origin: nil).and_return("%PDF-all")

      post flyers_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("%PDF-all")
    end

    it "prints uncategorized resources when no categories have been configured" do
      Category.delete_all
      allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
      source = Source.create!(name: "Local", source_type: "api")
      source.documents.create!(title: "Community noticeboard", content: "Noticeboard")

      post flyers_path

      expect(response).to have_http_status(:ok)
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("Other resources", "Community noticeboard")
    end

    it "re-renders the form when the flyer param is not a hash" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: "foo"}
      expect(response).to have_http_status(:unprocessable_content)

      post flyers_path, params: {flyer: ["x"]}
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects unknown categories" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: {categories: ["spaceships"]}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("spaceships")
    end

    it "records a temporary database outage and gives the user a useful message" do
      error = ActiveRecord::ConnectionNotEstablished.new("Private database connection detail")
      allow(FlyerGenerator).to receive(:call).and_raise(error)
      expect(Rails.error).to receive(:report).with(error, context: {feature: "category_flyer", categories: [food.id.to_s]})

      post flyers_path, params: {flyer: {categories: [food.id.to_s]}}

      expect(response).to redirect_to(new_flyer_path)
      follow_redirect!
      expect(response.body).to include("couldn&#39;t create the flyer")
    end

    it "returns structured validation errors for the live builder's PDF request" do
      post flyers_path, params: {flyer: {categories: ["unknown"]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Categories include unknown options: unknown")
    end

    it "rejects a malformed category filter instead of broadening it to all resources" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: {categories: food.id.to_s}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Categories must be provided as a list")
    end

    it "rejects an unsupported filter key instead of printing every resource" do
      expect(FlyerGenerator).not_to receive(:call)

      post flyers_path, params: {flyer: {category: food.id.to_s}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Unsupported flyer filters: category")
    end

    it "returns a structured empty-result error instead of following a redirect into HTML" do
      allow(FlyerGenerator).to receive(:call).and_return(nil)

      post flyers_path, params: {flyer: {categories: [food.id.to_s]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["errors"]).to include("No resources matched those categories. Try another selection.")
    end

    it "explains when the complete guide has no available resources" do
      allow(FlyerGenerator).to receive(:call).with(categories: [], origin: nil).and_return(nil)

      post flyers_path, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["errors"]).to include("No resources are available to print.")
    end

    it "shows the same complete-guide message after a standard form submission" do
      allow(FlyerGenerator).to receive(:call).with(categories: [], origin: nil).and_return(nil)

      post flyers_path, params: {flyer: {categories: [""]}}
      expect(response).to redirect_to(new_flyer_path)
      follow_redirect!

      expect(response.body).to include("No resources are available to print.")
    end

    it "reports a lost database connection with a safe structured message" do
      error = ActiveRecord::ConnectionFailed.new("Internal connection details")
      allow(FlyerGenerator).to receive(:call).and_raise(error)
      expect(Rails.error).to receive(:report).with(error, context: {feature: "category_flyer", categories: [food.id.to_s]})

      post flyers_path, params: {flyer: {categories: [food.id.to_s]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["errors"]).to include("We couldn't create the flyer. Please try again.")
      expect(response.body).not_to include("Internal connection details")
    end

    # The whole path from a submitted location to the generated PDF. Only the outside
    # service is faked: the query, card and PDF code all run for real.
    context "with a place to measure distances from" do
      let(:pdf_headers) { {"Accept" => "application/pdf"} }

      before do
        allow(ContentPipeline::Embedder).to receive(:embed).and_return(Array.new(1536, 0.0))
        Source.create!(name: "Local", source_type: "api").documents.create!(
          title: "Community meal", content: "Community meal", categories: [food],
          metadata: {address: "1 Test St", lat: 48.43, lng: -123.36}
        )
      end

      def pdf_text
        PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n").gsub(/\s+/, " ")
      end

      it "prints distances from the place that was entered" do
        expect(Geocoder).to receive(:locate).with("919 Pandora Ave, Victoria, BC")
          .and_return(GeoPoint.new(lat: 48.42, lng: -123.36))

        post flyers_path, params: {flyer: {near: "919 Pandora Ave"}}, headers: pdf_headers

        expect(response).to have_http_status(:ok)
        expect(pdf_text).to include("Distances are from 919 Pandora Ave", "Distance: 1.1 km straight-line, about 17 min walk")
      end

      it "doesn't look anything up when no place was entered" do
        expect(Geocoder).not_to receive(:locate)

        post flyers_path, params: {flyer: {near: "  "}}, headers: pdf_headers

        expect(response).to have_http_status(:ok)
        expect(pdf_text).not_to include("Distance")
      end

      it "asks for a correction when the place can't be found" do
        allow(Geocoder).to receive(:locate).and_return(nil)
        expect(FlyerGenerator).not_to receive(:call)

        post flyers_path, params: {flyer: {near: "Central Library"}}, headers: pdf_headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"].join).to include("couldn't find that location", "Douglas St and Yates St")
      end

      it "shows the form again with the typed text when submitted without JavaScript" do
        allow(Geocoder).to receive(:locate).and_return(nil)

        post flyers_path, params: {flyer: {near: "Central Library"}}

        expect(response).to have_http_status(:unprocessable_content)
        document = Nokogiri::HTML(response.body)
        expect(document.at_css('[role="alert"]').text).to include("couldn't find that location")
        expect(document.at_css('input[name="flyer[near]"]')["value"]).to eq("Central Library")
      end

      it "still prints, without distances, when the geocoder is down" do
        allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable, "HTTP 503")

        post flyers_path, params: {flyer: {near: "919 Pandora Ave"}}, headers: pdf_headers

        expect(response).to have_http_status(:ok)
        expect(pdf_text).to include("Community meal", "Distances aren't shown")
        expect(pdf_text).not_to include("Distance:")
      end

      it "rejects a location that isn't text" do
        expect(Geocoder).not_to receive(:locate)

        post flyers_path, params: {flyer: {near: ["919 Pandora Ave"]}}, headers: pdf_headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"]).to include("Near must be text")
      end

      it "rejects an unreasonably long location before looking it up" do
        expect(Geocoder).not_to receive(:locate)

        post flyers_path, params: {flyer: {near: "a" * 201}}, headers: pdf_headers

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "prints distances from the device's location without calling the geocoder" do
        expect(Geocoder).not_to receive(:locate)

        post flyers_path, params: {flyer: {lat: "48.420", lng: "-123.360"}}, headers: pdf_headers

        expect(response).to have_http_status(:ok)
        expect(pdf_text).to include("Distances are from your location", "Distance: 1.1 km straight-line, about 17 min walk")
        expect(pdf_text).not_to include("48.42", "123.36")
      end

      # The first screen already looked this place up, so printing shouldn't repeat it.
      it "uses a checked place's coordinates without looking it up again" do
        expect(Geocoder).not_to receive(:locate)

        post flyers_path, params: {flyer: {near: "919 Pandora Ave", lat: "48.420", lng: "-123.360"}}, headers: pdf_headers

        expect(pdf_text).to include("Distances are from 919 Pandora Ave", "Distance: 1.1 km")
      end

      it "treats the page's blank hidden fields as no device location" do
        post flyers_path, params: {flyer: {near: "", lat: "", lng: ""}}, headers: pdf_headers

        expect(response).to have_http_status(:ok)
        expect(pdf_text).not_to include("Distance")
      end

      it "rejects an unusable device location" do
        expect(FlyerGenerator).not_to receive(:call)

        post flyers_path, params: {flyer: {lat: "999", lng: "-123.360"}}, headers: pdf_headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"].join).to include("couldn't read your device's location")
      end

      it "rejects coordinates that aren't text" do
        post flyers_path, params: {flyer: {lat: ["48.42"], lng: "-123.36"}}, headers: pdf_headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"]).to include("Lat must be text")
      end

      # A location may be someone's home, so it must not reach the logs.
      it "filters the location from logged parameters" do
        filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

        expect(filter.filter("flyer" => {"near" => "919 Pandora Ave", "lat" => "48.42", "lng" => "-123.36"}))
          .to eq("flyer" => {"near" => "[FILTERED]", "lat" => "[FILTERED]", "lng" => "[FILTERED]"})
      end

      it "doesn't hide unrelated parameters whose names contain lat" do
        filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

        expect(filter.filter("template" => "a")).to eq("template" => "a")
      end
    end

    it "lets a programming error in PDF generation fail visibly" do
      allow(FlyerGenerator).to receive(:call).and_raise(NoMethodError, "Unexpected renderer bug")

      expect {
        post flyers_path, params: {flyer: {categories: [food.id.to_s]}}, headers: {"Accept" => "application/pdf"}
      }.to raise_error(NoMethodError, "Unexpected renderer bug")
    end
  end

  # The check behind the first screen's Continue button. It only says whether a place
  # can be found, so that the person can correct it before choosing categories.
  describe "POST /printout/locate" do
    def locate(near)
      post locate_flyers_path(format: :json), params: {flyer: {near: near}}
    end

    it "returns a found place's coordinates, rounded to about 100 m" do
      expect(Geocoder).to receive(:locate).with("919 Pandora Ave, Victoria, BC")
        .and_return(GeoPoint.new(lat: 48.4271129, lng: -123.3577635))

      locate("919 Pandora Ave")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("located" => true, "lat" => 48.427, "lng" => -123.358)
    end

    it "explains what to try when a place can't be found" do
      allow(Geocoder).to receive(:locate).and_return(nil)

      locate("Central Library")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].join).to include("couldn't find that location", "Douglas St and Yates St")
    end

    it "treats a blank place as not found, without calling the geocoder" do
      expect(Geocoder).not_to receive(:locate)

      locate("  ")

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "lets the person carry on when the geocoder is down" do
      allow(Geocoder).to receive(:locate).and_raise(Geocoder::Unavailable, "HTTP 503")

      locate("919 Pandora Ave")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("located" => false)
    end

    it "rejects unreasonably long text before calling the geocoder" do
      expect(Geocoder).not_to receive(:locate)

      locate("a" * 201)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a place that isn't text" do
      expect(Geocoder).not_to receive(:locate)

      post locate_flyers_path(format: :json), params: {flyer: {near: ["919 Pandora Ave"]}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Near must be text")
    end

    it "limits checks per connection, with an error the page can show" do
      allow(Geocoder).to receive(:locate).and_return(nil)

      60.times { locate("Somewhere") }
      expect(response).to have_http_status(:unprocessable_content)

      locate("Somewhere")
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["errors"].join).to include("try again later")
    end
  end

  describe "GET /printout/preview" do
    before do
      allow(ContentPipeline::Embedder).to receive(:embed).and_return([1.0] + Array.new(1535, 0.0))
      source = Source.create!(name: "Local", source_type: "api")
      source.documents.create!(title: "Community meal", content: "Community meal", categories: [food], metadata: {notes: "Call ahead"})
      source.documents.create!(title: "Unrelated clinic", content: "Clinic", categories: [health])
    end

    # The preview should show the same distances as the printout, using the same card
    # code. It must never call the geocoder: it runs each time a category changes.
    context "with a chosen location" do
      before do
        Document.find_by!(title: "Community meal").update_columns(metadata: {lat: 48.43, lng: -123.36})
      end

      def card_fields(title)
        cards = response.parsed_body["categories"].flat_map { |category| category["resources"] }
        cards.find { |card| card["title"] == title }["fields"]
      end

      it "shows distances from coordinates sent in the request body" do
        expect(Geocoder).not_to receive(:locate)

        post preview_flyers_path(format: :json), params: {flyer: {lat: "48.420", lng: "-123.360"}}

        expect(response).to have_http_status(:ok)
        expect(card_fields("Community meal"))
          .to include({"label" => "Distance", "value" => "1.1 km straight-line, about 17 min walk"})
      end

      it "applies the selected categories and the location together" do
        post preview_flyers_path(format: :json), params: {flyer: {categories: [food.id.to_s], lat: "48.420", lng: "-123.360"}}

        titles = response.parsed_body["categories"].flat_map { |category| category["resources"].map { |card| card["title"] } }
        expect(titles).to eq(["Community meal"])
        expect(card_fields("Community meal").map { |field| field["label"] }).to include("Distance")
      end

      it "has no distance row for a resource whose location isn't known" do
        post preview_flyers_path(format: :json), params: {flyer: {lat: "48.420", lng: "-123.360"}}

        expect(card_fields("Unrelated clinic").map { |field| field["label"] }).not_to include("Distance")
      end

      it "shows no distances without coordinates" do
        get preview_flyers_path(format: :json)

        expect(card_fields("Community meal").map { |field| field["label"] }).not_to include("Distance")
      end

      it "ignores a typed place rather than calling the geocoder" do
        expect(Geocoder).not_to receive(:locate)

        post preview_flyers_path(format: :json), params: {flyer: {near: "919 Pandora Ave"}}

        expect(response).to have_http_status(:ok)
        expect(card_fields("Community meal").map { |field| field["label"] }).not_to include("Distance")
      end

      it "rejects unusable coordinates" do
        post preview_flyers_path(format: :json), params: {flyer: {lat: "999", lng: "-123.360"}}

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it "redirects a filtered HTML preview to the builder with its selection" do
      expect(CategorySearch).not_to receive(:call)

      get preview_flyers_path, params: {flyer: {categories: [food.id.to_s]}}

      expect(response).to redirect_to(new_flyer_path(flyer: {categories: [food.id.to_s]}))
      follow_redirect!

      document = Nokogiri::HTML(response.body)
      expect(document.css('input[type="checkbox"][checked]').map { |input| input["value"] }).to eq([food.id.to_s])
    end

    it "redirects an unfiltered HTML preview to the complete builder" do
      expect(CategorySearch).not_to receive(:call)

      get preview_flyers_path

      expect(response).to redirect_to(new_flyer_path)
    end

    it "still rejects an invalid category in an HTML preview link" do
      get preview_flyers_path, params: {flyer: {categories: ["unknown"]}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("unknown")
    end

    it "returns the same filtered data as JSON for the front-end integration" do
      get preview_flyers_path(format: :json), params: {flyer: {categories: [food.id.to_s]}}

      expect(response).to have_http_status(:ok)
      category = response.parsed_body.fetch("categories").first
      expect(category["key"]).to eq(food.id.to_s)
      expect(category["resources"].map { |resource| resource["title"] }).to eq(["Community meal"])
      expect(category["resources"].first["fields"]).to include({"label" => "Notes", "value" => "Call ahead"})
    end

    it "offers new database categories and uses their renamed labels in both preview and PDF" do
      category = Category.create!(name: "Computer access")
      source = Source.find_by!(name: "Local")
      listing = source.documents.create!(title: "Community computers", content: "Computers", categories: [category])

      get new_flyer_path

      checkbox = Nokogiri::HTML(response.body).at_css("input[type='checkbox'][value='#{category.id}']")
      expect(checkbox).to be_present
      expect(response.body).to include("Computer access")

      category.update!(name: "Internet access")
      selection = {flyer: {categories: [category.id.to_s]}}
      get preview_flyers_path(format: :json), params: selection

      group = response.parsed_body.fetch("categories").sole
      expect(group).to include("key" => category.id.to_s, "name" => "Internet access")
      expect(group.fetch("resources").map { |resource| resource.fetch("id") }).to eq([listing.id])

      post flyers_path, params: selection, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:ok)
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("Internet access", "Community computers")
      expect(text).not_to include("Computer access", "Community meal", "Unrelated clinic")
    end

    it "includes a category-tagged resource without an embedding in the preview and PDF" do
      source = Source.find_by!(name: "Local")
      listing = source.documents.create!(title: "Offline listing", content: "Offline listing", categories: [food])
      listing.update_column(:embedding, nil)

      get preview_flyers_path(format: :json), params: {flyer: {categories: [food.id.to_s]}}

      expect(response).to have_http_status(:ok)
      titles = response.parsed_body.fetch("categories").first.fetch("resources").map { |resource| resource.fetch("title") }
      expect(titles).to include("Offline listing")

      post flyers_path, params: {flyer: {categories: [food.id.to_s]}}, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:ok)
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("Offline listing")
    end

    it "shows all visible resources in JSON when no filters are specified" do
      get preview_flyers_path(format: :json)

      expect(response).to have_http_status(:ok)
      resources = response.parsed_body.fetch("categories").flat_map { |category| category.fetch("resources") }
      expect(resources.map { |resource| resource["title"] }).to contain_exactly("Community meal", "Unrelated clinic")
    end

    it "restores all resources when the category selection is cleared" do
      get preview_flyers_path(format: :json), params: {flyer: {categories: [""]}}

      expect(response).to have_http_status(:ok)
      resources = response.parsed_body.fetch("categories").flat_map { |category| category.fetch("resources") }
      expect(resources.map { |resource| resource["title"] }).to contain_exactly("Community meal", "Unrelated clinic")
    end

    it "generates a complete PDF without category filters" do
      post flyers_path, headers: {"Accept" => "application/pdf"}

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("Community meal", "Unrelated clinic")
    end

    it "rejects malformed preview filters instead of treating them as an empty selection" do
      get preview_flyers_path(format: :json), params: {flyer: {categories: food.id.to_s}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to include("Categories must be provided as a list")
    end

    it "rejects invalid category selections in JSON" do
      get preview_flyers_path(format: :json), params: {flyer: {categories: ["unknown"]}}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to be_present
    end

    it "renders a usable PDF through the existing create action" do
      post flyers_path, params: {flyer: {categories: [food.id.to_s]}}

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF-")
    end

    it "records a temporary database outage without exposing details to the front end" do
      error = ActiveRecord::ConnectionNotEstablished.new("Private database connection detail")
      allow(CategorySearch).to receive(:call).and_raise(error)
      expect(Rails.error).to receive(:report).with(error, context: {feature: "category_preview", categories: [food.id.to_s]})

      get preview_flyers_path(format: :json), params: {flyer: {categories: [food.id.to_s]}}

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["errors"]).to include("We couldn't load those resources. Please try again.")
      expect(response.body).not_to include("Private database connection detail")
    end

    it "lets a programming error in the preview fail visibly" do
      allow(CategorySearch).to receive(:call).and_raise(NoMethodError, "Unexpected query bug")

      expect {
        get preview_flyers_path(format: :json), params: {flyer: {categories: [food.id.to_s]}}
      }.to raise_error(NoMethodError, "Unexpected query bug")
    end

    it "does not hide a SQL bug as a temporary outage" do
      allow(CategorySearch).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "Bad SQL")

      expect {
        get preview_flyers_path(format: :json), params: {flyer: {categories: [food.id.to_s]}}
      }.to raise_error(ActiveRecord::StatementInvalid, "Bad SQL")
    end
  end
end
