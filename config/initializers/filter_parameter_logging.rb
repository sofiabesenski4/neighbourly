# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # What people ask the assistant is as sensitive as anything else here — someone
  # asking where to sleep tonight should not have that sitting in a log file.
  :content, :prompt, :details, :query, "flyer.categories",
  # The place someone measures a printout's distances from may be their home.
  # Plain names here match anywhere in a parameter's name, so "lat" would also hide
  # names like "template". The pattern matches only these exact names.
  :near, /\A(lat|lng)\z/,
  # Questionnaire answers. Every one is nested under this name, so this hides them all,
  # including those of questions added later. Don't add names like :age here: plain names
  # match anywhere, so it would also hide "message" and "language".
  :questionnaire
]
