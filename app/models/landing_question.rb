class LandingQuestion
  include ActiveModel::Model

  MAX_LENGTH = 2000
  DRAFT_LIFETIME = 30.minutes

  attr_accessor :prompt

  validates :prompt, presence: {message: "Enter a question to start your chat."},
    length: {maximum: MAX_LENGTH, message: "Keep your question to 2,000 characters or fewer."}

  def self.restore(token)
    new(prompt: token.present? ? Rails.cache.read("landing_question:#{token}") : nil)
  end

  def self.forget(token)
    Rails.cache.delete("landing_question:#{token}") if token.present?
  end

  # Only this random reference goes into the session cookie. The unsent question
  # stays in the server cache for a short time, including through sign-in retries.
  def remember(token = nil)
    token ||= SecureRandom.hex(24)
    token if Rails.cache.write("landing_question:#{token}", prompt, expires_in: DRAFT_LIFETIME)
  end
end
