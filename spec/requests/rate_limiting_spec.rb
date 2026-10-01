require "rails_helper"

# Rate limits are declared per action with Rails' built-in `rate_limit`. They
# count through Action Controller's cache store, which rails_helper clears
# between examples so counters do not leak across specs.
RSpec.describe "Rate limiting", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { User.create!(email: "user@example.com", password: "password123") }
  let(:other_user) { User.create!(email: "other@example.com", password: "password123") }

  describe "POST /users/sign_in" do
    def attempt(email, password: "wrong-password")
      post user_session_path, params: {user: {email: email, password: password}}
    end

    before { user }

    it "allows attempts up to the per-email limit" do
      10.times { attempt(user.email) }

      expect(flash[:alert]).to eq("Invalid email or password.")
    end

    it "turns away further guesses at the same account" do
      10.times { attempt(user.email) }

      attempt(user.email)

      expect(flash[:alert]).to match(/too many sign-in attempts for that account/i)
    end

    it "keeps the correct password from working once the limit is tripped" do
      10.times { attempt(user.email) }

      attempt(user.email, password: "password123")
      expect(flash[:alert]).to match(/too many sign-in attempts for that account/i)

      get chats_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "does not lock out a different account on the same connection" do
      10.times { attempt(user.email) }

      attempt(other_user.email, password: "password123")

      expect(flash[:alert]).to be_nil
      get chats_path
      expect(response).to have_http_status(:ok)
    end

    it "is case-insensitive about the account being guessed" do
      10.times { attempt(user.email.upcase) }

      attempt(user.email)

      expect(flash[:alert]).to match(/too many sign-in attempts for that account/i)
    end
  end

  describe "POST /users/password" do
    def request_reset(email)
      post user_password_path, params: {user: {email: email}}
    end

    before { user }

    it "allows reset requests up to the per-email limit" do
      expect { 3.times { request_reset(user.email) } }
        .to change { ActionMailer::Base.deliveries.count }.by(3)
    end

    it "stops mailing the same address once the limit is tripped" do
      3.times { request_reset(user.email) }

      expect { request_reset(user.email) }
        .not_to change { ActionMailer::Base.deliveries.count }

      expect(flash[:alert]).to match(/already sent reset instructions/i)
    end

    it "still allows a reset for a different address" do
      3.times { request_reset(user.email) }

      expect { request_reset(other_user.email) }
        .to change { ActionMailer::Base.deliveries.count }.by(1)
    end
  end

  describe "POST /users (registration)" do
    def register(email)
      sign_out :user
      post user_registration_path, params: {
        user: {email: email, password: "password123", password_confirmation: "password123"}
      }
    end

    it "allows signups up to the per-IP limit" do
      expect { 20.times { |i| register("signup#{i}@example.com") } }
        .to change(User, :count).by(20)
    end

    it "turns away further signups from the same connection" do
      20.times { |i| register("signup#{i}@example.com") }

      expect { register("one-more@example.com") }.not_to change(User, :count)

      expect(flash[:alert]).to match(/a lot of accounts have been created/i)
    end

    it "stops a retry loop on a single address" do
      3.times { register("taken@example.com") }

      expect { register("taken@example.com") }.not_to change(User, :count)

      expect(flash[:alert]).to match(/already in progress/i)
    end
  end

  describe "POST /chats" do
    let(:params) { {chat: {prompt: "where can I find a meal tonight?"}} }

    before { sign_in user }

    it "allows requests up to the burst limit" do
      5.times { post chats_path, params: params }

      expect(response).to redirect_to(chat_path(Chat.last))
      expect(Chat.count).to eq(5)
    end

    it "turns the next request away with an explanation" do
      5.times { post chats_path, params: params }

      expect { post chats_path, params: params }.not_to change(Chat, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/starting new chats too quickly/i)
    end

    it "counts per user rather than per IP" do
      5.times { post chats_path, params: params }
      sign_in other_user

      expect { post chats_path, params: params }.to change(Chat, :count).by(1)

      expect(flash[:alert]).to be_nil
    end
  end

  describe "POST /reports (anonymous)" do
    let(:fake_vector) { Array.new(1536, 0.0) }
    let(:source) { Source.create!(name: "Test", url: "https://example.com", source_type: "api") }
    let(:document) { source.documents.create!(title: "Test Shelter", content: "Test", external_id: "1") }
    let(:other_document) { source.documents.create!(title: "Other Shelter", content: "Test", external_id: "2") }

    before { allow(ContentPipeline::Embedder).to receive(:embed).and_return(fake_vector) }

    def submit(doc)
      post reports_path, params: {report: {document_id: doc.id, reason: "out of date"}}
    end

    it "allows repeat reports on one listing up to the per-document limit" do
      expect { 3.times { submit(document) } }.to change(Report, :count).by(3)
    end

    it "turns away a fourth report on the same listing" do
      3.times { submit(document) }

      expect { submit(document) }.not_to change(Report, :count)

      expect(flash[:alert]).to match(/already reported this listing/i)
    end

    it "still accepts reports on a different listing from the same connection" do
      3.times { submit(document) }

      expect { submit(other_document) }.to change(Report, :count).by(1)

      expect(flash[:alert]).to be_nil
    end

    it "stops a flood across many listings at the per-IP ceiling" do
      30.times do |i|
        doc = source.documents.create!(title: "Shelter #{i}", content: "Test", external_id: "flood-#{i}")
        submit(doc)
      end

      expect { submit(other_document) }.not_to change(Report, :count)

      expect(flash[:alert]).to match(/a lot of reports from this connection/i)
    end
  end

  describe "POST /chats/:chat_id/messages" do
    let(:chat) { user.chats.create! }
    let(:params) { {message: {content: "hello"}} }

    before { sign_in user }

    it "allows requests up to the burst limit" do
      expect {
        10.times { post chat_messages_path(chat), params: params }
      }.to have_enqueued_job(ChatResponseJob).exactly(10).times
    end

    it "turns the next request away with an explanation" do
      10.times { post chat_messages_path(chat), params: params }

      expect {
        post chat_messages_path(chat), params: params
      }.not_to have_enqueued_job(ChatResponseJob)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/faster than we can answer/i)
    end

    it "counts per user rather than per IP" do
      10.times { post chat_messages_path(chat), params: params }
      other_chat = other_user.chats.create!
      sign_in other_user

      expect {
        post chat_messages_path(other_chat), params: params
      }.to have_enqueued_job(ChatResponseJob)

      expect(flash[:alert]).to be_nil
    end
  end
end
