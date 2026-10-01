require "rails_helper"

RSpec.describe "Documents", type: :system do
  before do
    driven_by(:rack_test)
  end

  let(:admin) { User.create!(email: "admin@example.com", password: "password123", admin: true) }
  let(:regular_user) { User.create!(email: "user@example.com", password: "password123", admin: false) }
  let(:fake_vector) { Array.new(1536) { rand(-1.0..1.0) } }

  before do
    allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector)
  end

  describe "authorization" do
    it "prevents non-admin users from accessing the add resource form" do
      login_as(regular_user, scope: :user)
      visit new_document_path

      expect(page).to have_content("You are not authorized to perform this action.")
    end
  end

  context "as an admin" do
    before { login_as(admin, scope: :user) }

    describe "creating a resource" do
      it "creates a document with all fields" do
        visit new_document_path

        fill_in "Resource name", with: "Harbour Street Society"
        fill_in "Description of services", with: "Drop-in centre offering meals and shelter"
        fill_in "City", with: "Victoria"
        fill_in "Street address", with: "100 Harbour St"
        fill_in "Phone number(s)", with: "250-555-0100"
        fill_in "Email", with: "info@example.org"
        fill_in "Website", with: "https://example.org"
        fill_in "Hours of operation", with: "Mon-Sun 7am-11pm"
        fill_in "Categories", with: "shelter, meals"
        fill_in "Minimum age", with: "19"
        fill_in "Maximum age", with: "65"
        fill_in "Gender", with: "all"
        fill_in "Additional notes", with: "No referral needed"

        click_button "Create resource"

        expect(page).to have_content("Resource 'Harbour Street Society' was created.")
        expect(Document.last.title).to eq("Harbour Street Society")
        expect(Document.last.metadata["city"]).to eq("Victoria")
        expect(Document.last.metadata["categories"]).to eq(["shelter", "meals"])
        expect(Document.last.metadata["age_range"]).to eq({"min" => 19, "max" => 65})
      end

      it "creates a document with only required fields" do
        visit new_document_path

        fill_in "Resource name", with: "Minimal Resource"
        fill_in "Description of services", with: "Basic description"

        click_button "Create resource"

        expect(page).to have_content("Resource 'Minimal Resource' was created.")
        expect(Document.last.title).to eq("Minimal Resource")
      end

      it "shows validation errors when title and description are blank" do
        visit new_document_path

        click_button "Create resource"

        expect(page).to have_content("error")
      end
    end

    describe "viewing a resource" do
      it "displays document details" do
        source = Source.form_entry_source
        doc = source.documents.create!(
          title: "Lantern House Society",
          content: "Lantern House Society\nCity: Victoria",
          metadata: {
            city: "Victoria",
            address: "200 Lantern Way",
            phone: ["250-555-0101"],
            hours: "24/7",
            categories: ["shelter", "health"],
            description: "Housing and health services"
          }
        )

        visit document_path(doc)

        expect(page).to have_content("Lantern House Society")
        expect(page).to have_content("Victoria")
        expect(page).to have_content("200 Lantern Way")
        expect(page).to have_content("250-555-0101")
        expect(page).to have_content("24/7")
        expect(page).to have_content("shelter, health")
        expect(page).to have_content("Housing and health services")
      end
    end

    describe "editing a resource" do
      it "updates the document" do
        source = Source.form_entry_source
        doc = source.documents.create!(
          title: "Old Name",
          content: "Old Name\nCity: Victoria",
          metadata: {city: "Victoria"}
        )

        visit edit_document_path(doc)

        fill_in "Resource name", with: "New Name"
        fill_in "City", with: "Nanaimo"

        click_button "Update resource"

        expect(page).to have_content("Resource 'New Name' was updated.")
        doc.reload
        expect(doc.title).to eq("New Name")
        expect(doc.metadata["city"]).to eq("Nanaimo")
      end
    end
  end
end
