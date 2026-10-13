# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # The unlisted-project credential, `?k=<token>` (Public::BaseController#unlisted_token_ok?).
  # ANCHORED: a String entry matches as a SUBSTRING of the key, so a bare `:k` would redact
  # `kind`, `block_id`, every key containing a k (test/lib/parameter_filter_test.rb pins both halves).
  /\Ak\z/
]
