require "rails_helper"
require "tmpdir"

RSpec.describe "Sources", type: :system do
  include ActiveJob::TestHelper

  before do
    driven_by(:rack_test)
  end

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", admin: false) }
  let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)

    # CSV rows are enriched after ingestion. Reply with a summary of the row.
    chat = instance_double(RubyLLM::Chat)
    allow(RubyLLM).to receive(:chat).and_return(chat)
    allow(chat).to receive_messages(with_instructions: chat, with_schema: chat)
    allow(chat).to receive(:ask) do |prompt|
      name = JSON.parse(prompt[/^Row: (.*)$/, 1])["Name"]
      instance_double(RubyLLM::Message, content: {title: name, summary: "#{name} is a local service.", categories: []}.to_json)
    end
  end

  after do
    @temp_dirs&.each { |dir| FileUtils.remove_entry(dir) }
  end

  describe "authorization" do
    it "prevents non-admin users from accessing sources index" do
      login_as(regular_user, scope: :user)
      visit sources_path

      expect(page).to have_content("You are not authorized to perform this action.")
    end

    it "prevents non-admin users from accessing the upload form" do
      login_as(regular_user, scope: :user)
      visit new_source_path

      expect(page).to have_content("You are not authorized to perform this action.")
    end

    it "redirects guests to sign in" do
      visit sources_path

      expect(page).to have_content("Sign in to your account")
    end
  end

  context "as an admin" do
    before { login_as(admin, scope: :user) }

    it "makes Sources reachable through the admin console" do
      visit root_path
      click_link "Admin console", exact: true
      within("[aria-label='Administration sections']") do
        expect(page).to have_link("Sources", href: sources_path)
      end
    end

    it "lists existing sources on the index page" do
      source = Source.create!(name: "BC 211 Shelters", url: "https://example.com/shelters", source_type: "api")
      source.documents.create!(content: "test", external_id: "1")

      visit sources_path

      expect(page).to have_content("BC 211 Shelters")
      expect(page).to have_content("API")
      expect(page).to have_content("1 document")
    end

    it "subscribes the sources list to one refresh stream" do
      2.times { |i| Source.create!(name: "Uploaded #{i}", source_type: "csv") }

      visit sources_path

      expect(page).to have_css("turbo-cable-stream-source", count: 1, visible: :all)
    end

    it "shows an empty state when no sources exist" do
      visit sources_path
      expect(page).to have_content("No sources have been added yet.")
    end

    it "shows the Add resource button" do
      visit sources_path
      expect(page).to have_link("Add resource", href: new_document_path)
    end

    it "shows form-created documents on the sources page" do
      form_source = Source.form_entry_source
      Category.find_or_create_by!(name: "Shelters")
      form_source.documents.create!(title: "Manual Resource", content: "test", category_names: ["Shelters"], metadata: {city: "Victoria"})

      visit sources_path

      expect(page).to have_content("Manual Resource")
      expect(page).to have_content("FORM")
      expect(page).to have_content("Victoria")
      expect(page).to have_content("Shelters")
    end

    describe "viewing a source" do
      it "shows the source details and its documents" do
        source = Source.create!(name: "BC 211 Shelters", url: "https://example.com/shelters", source_type: "api")
        source.documents.create!(content: "My Shelter\nCity: Victoria", title: "My Shelter", external_id: "1", metadata: {city: "Victoria"})

        visit source_path(source)

        expect(page).to have_content("BC 211 Shelters")
        expect(page).to have_content("API")
        expect(page).to have_content("My Shelter")
        expect(page).to have_content("Victoria")
      end

      it "links to source show from the index" do
        source = Source.create!(name: "Test Source", url: "https://example.com/test", source_type: "api")

        visit sources_path
        click_link "Test Source"

        expect(page).to have_current_path(source_path(source))
      end

      it "allows deleting an individual document from a source" do
        source = Source.create!(name: "Test Source", url: "https://example.com/test", source_type: "api")
        source.documents.create!(content: "Doc A", title: "Doc A", external_id: "a")
        doc_b = source.documents.create!(content: "Doc B", title: "Doc B", external_id: "b")

        visit source_path(source)

        within("#document_#{doc_b.id}") do
          click_button "Delete"
        end

        expect(page).to have_content("Resource 'Doc B' was deleted")
        expect(page).to have_content("Doc A")
        expect(source.documents.count).to eq(1)
      end

      it "shows an empty state when a source has no documents" do
        source = Source.create!(name: "Empty Source", url: "https://example.com/empty", source_type: "api")

        visit source_path(source)

        expect(page).to have_content("No documents in this source.")
      end
    end

    describe "uploading a JSON source" do
      it "creates a source and ingests documents from a JSON file" do
        visit new_source_path

        fill_in "Source name", with: "Test Shelters"
        fill_in "Origin URL", with: "https://example.com/shelters.json"
        select "JSON (structured API data)", from: "Data type"

        json_content = [{"id" => 1, "post_title" => "My Shelter", "location" => {"city" => {"label" => "Victoria"}}}].to_json
        file = create_temp_file("shelters.json", json_content)
        attach_file "Upload file", file.path

        perform_enqueued_jobs { click_button "Upload and ingest" }

        expect(page).to have_content("Source 'Test Shelters' created. Its documents are being ingested in the background.")
        expect(page).to have_content("1 document")
        expect(Source.last.name).to eq("Test Shelters")
        expect(Document.last.title).to eq("My Shelter")
      end
    end

    describe "uploading an HTML source" do
      it "creates a source and ingests documents from an HTML file" do
        visit new_source_path

        fill_in "Source name", with: "Harbour Street Meals"
        fill_in "Origin URL", with: "https://example.com/meals"
        select "HTML (web page)", from: "Data type"

        html_content = "<html><head><title>Meals</title></head><body><p>Free meals daily at 100 Harbour St.</p></body></html>"
        file = create_temp_file("meals.html", html_content)
        attach_file "Upload file", file.path

        perform_enqueued_jobs { click_button "Upload and ingest" }

        expect(page).to have_content("Source 'Harbour Street Meals' created. Its documents are being ingested in the background.")
        expect(page).to have_content("1 document")
        expect(Document.last.content).to include("Free meals daily")
      end
    end

    describe "uploading a CSV source" do
      it "creates a source and ingests one document per row" do
        visit new_source_path

        fill_in "Source name", with: "Drop-in Centres"
        select "CSV (spreadsheet rows)", from: "Data type"
        check "Summarize and categorize rows with AI (CSV only)"

        file = create_temp_file("centres.csv", "Name,Address\nHarbour Meals,100 Harbour St\nNorthside Shelter,22 North Rd\n")
        attach_file "Upload file", file.path

        perform_enqueued_jobs { click_button "Upload and ingest" }

        expect(page).to have_content("Source 'Drop-in Centres' created. Its documents are being ingested in the background.")
        expect(page).to have_content("2 document")
        expect(Source.last).to be_csv
        document = Document.find_by!(title: "Harbour Meals")
        expect(document.metadata).to include("Address" => "100 Harbour St")
        expect(document.content).to eq("Harbour Meals is a local service.\n\nName: Harbour Meals\nAddress: 100 Harbour St")
        expect(document.enriched_at).to be_present
        expect(page).to have_content("AI summaries")
      end

      it "keeps rows as uploaded when AI summaries are not chosen" do
        visit new_source_path

        fill_in "Source name", with: "Drop-in Centres"
        select "CSV (spreadsheet rows)", from: "Data type"
        attach_file "Upload file", create_temp_file("centres.csv", "Name,Address\nHarbour Meals,100 Harbour St\n").path

        perform_enqueued_jobs { click_button "Upload and ingest" }

        document = Document.find_by!(title: "Harbour Meals")
        expect(document.content).to eq("Name: Harbour Meals\nAddress: 100 Harbour St")
        expect(document.enriched_at).to be_nil
        expect(RubyLLM).not_to have_received(:chat)
        expect(page).not_to have_content("AI summaries")
      end

      it "shows an error and keeps no source when the CSV is malformed" do
        visit new_source_path

        fill_in "Source name", with: "Broken CSV"
        select "CSV (spreadsheet rows)", from: "Data type"

        file = create_temp_file("broken.csv", "Name,Notes\nHarbour,\"unclosed\n")
        attach_file "Upload file", file.path

        click_button "Upload and ingest"

        expect(page).to have_content("File could not be read as CSV")
        expect(page).to have_field("Source name", with: "Broken CSV")
        expect(Source.count).to eq(0)
      end
    end

    describe "ingesting in the background" do
      def upload_csv
        visit new_source_path
        fill_in "Source name", with: "Drop-in Centres"
        select "CSV (spreadsheet rows)", from: "Data type"
        attach_file "Upload file", create_temp_file("centres.csv", "Name\nHarbour Meals\n").path
        click_button "Upload and ingest"
      end

      it "queues the upload and shows that it is waiting" do
        expect { upload_csv }.to have_enqueued_job(IngestSourceJob)

        expect(page).to have_content("Waiting to ingest")
        expect(page).to have_content("0 documents")
        expect(Source.last).to be_ingestion_pending
      end

      it "subscribes the source page to refreshes while the upload is ingested" do
        upload_csv

        expect(page).to have_css("turbo-cable-stream-source", visible: :all)
        expect(page).to have_css("meta[name='turbo-refresh-method'][content='morph']", visible: :all)
        expect(page).to have_content("This page updates when ingestion finishes.")
      end

      it "marks the source failed when its ingestion cannot be queued" do
        allow(IngestSourceJob).to receive(:perform_later).and_return(false)
        upload_csv

        expect(page).to have_content("Source 'Drop-in Centres' was created, but its ingestion could not be started.")
        expect(page).to have_content("Ingestion failed")
        expect(page).to have_content("Ingestion could not be queued.")
        expect(Source.last.upload_content).to be_present
      end

      it "marks the source failed when the queue raises" do
        allow(IngestSourceJob).to receive(:perform_later).and_raise(SolidQueue::Job::EnqueueError, "database unavailable")
        upload_csv

        expect(page).to have_content("Ingestion could not be queued: database unavailable")
        expect(Source.last).to be_ingestion_failed
      end

      it "shows the error when ingestion fails" do
        allow(ContentPipeline::Embedder).to receive(:embed).and_raise(RubyLLM::Error, "embedding service unavailable")
        upload_csv

        expect { perform_enqueued_jobs }.to raise_error(ActiveRecord::RecordNotSaved)
        visit source_path(Source.last)

        expect(page).to have_content("Ingestion failed")
        expect(page).to have_content("Ingestion stopped with an error")
        expect(page).to have_content("Failed to generate embedding: embedding service unavailable")
      end
    end

    describe "validation errors" do
      it "requires a file to be uploaded" do
        visit new_source_path

        fill_in "Source name", with: "No File"
        fill_in "Origin URL", with: "https://example.com/nofile"
        select "JSON (structured API data)", from: "Data type"
        click_button "Upload and ingest"

        expect(page).to have_content("File must be provided")
      end

      it "rejects wrong file types for the source type" do
        visit new_source_path

        fill_in "Source name", with: "Wrong Type"
        fill_in "Origin URL", with: "https://example.com/wrong"
        select "JSON (structured API data)", from: "Data type"

        file = create_temp_file("page.html", "<html><body>test</body></html>")
        attach_file "Upload file", file.path
        click_button "Upload and ingest"

        expect(page).to have_content("File must be a .json file for API sources")
      end

      it "rejects a non-CSV file for a CSV source" do
        visit new_source_path

        fill_in "Source name", with: "Wrong Type"
        select "CSV (spreadsheet rows)", from: "Data type"

        file = create_temp_file("data.json", [{"id" => 1}].to_json)
        attach_file "Upload file", file.path
        click_button "Upload and ingest"

        expect(page).to have_content("a .csv file for CSV sources")
      end

      it "requires a source name" do
        visit new_source_path

        fill_in "Origin URL", with: "https://example.com/noname"
        select "JSON (structured API data)", from: "Data type"

        file = create_temp_file("data.json", [{"id" => 1, "post_title" => "Test"}].to_json)
        attach_file "Upload file", file.path
        click_button "Upload and ingest"

        expect(page).to have_content("Name can't be blank")
      end
    end

    describe "deleting a source" do
      it "deletes the source and all its documents" do
        source = Source.create!(name: "To Delete", url: "https://example.com/delete", source_type: "api")
        source.documents.create!(content: "doc", external_id: "1")

        visit sources_path
        click_button "Delete"

        expect(page).to have_content("Source 'To Delete' was deleted.")
        expect(Source.count).to eq(0)
        expect(Document.count).to eq(0)
      end
    end
  end

  context "as a regular user" do
    before { login_as(regular_user, scope: :user) }

    it "does not show the Sources link in the nav" do
      visit root_path
      expect(page).not_to have_link("Sources")
    end
  end

  private

  # Each call gets its own temp directory, cleaned up after the example. This
  # used to write to a hardcoded absolute path under one developer's macOS
  # TMPDIR, which meant these examples only passed on that machine and failed
  # with ENOENT everywhere else, CI included.
  def create_temp_file(filename, content)
    dir = Dir.mktmpdir("sources-spec")
    (@temp_dirs ||= []) << dir
    path = File.join(dir, filename)
    File.write(path, content)
    File.new(path)
  end
end
