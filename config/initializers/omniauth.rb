# OmniAuth/OIDC provider wiring — INERT unless OMNIAUTH_ENABLED is set (no hosted-IdP deps
# ship active; CLAUDE.md §9). Devise mounts the omniauthable routes from the model's
# omniauth_providers; this configures the strategy credentials when enabled.
if ENV["OMNIAUTH_ENABLED"].present?
  # THE STRATEGY IS LOADED HERE, BESIDE THE ONLY LINE THAT NEEDS IT. The gem is `require: false`
  # (Gemfile) so that a deployment without single sign-on never loads it; without this line the
  # boot died in Devise's railtie with StrategyNotFound, because the class and the camelization
  # that names it (`OpenIDConnect`, not `OpenidConnect`) both live inside the gem.
  # test/omniauth_boot_test.rb boots a child process with the switch on.
  require "omniauth_openid_connect"

  Devise.setup do |config|
    config.omniauth :openid_connect, {
      name: :openid_connect,
      scope: %i[openid email],
      response_type: :code,
      issuer: ENV["OIDC_ISSUER"],
      discovery: true,
      client_options: {
        identifier:   ENV["OIDC_CLIENT_ID"],
        secret:       ENV["OIDC_CLIENT_SECRET"],
        redirect_uri: ENV["OIDC_REDIRECT_URI"]
      }
    }
  end
end

# CSRF protection for the OmniAuth request phase (omniauth-rails_csrf_protection, MIT).
# Loaded unconditionally; harmless when no provider is configured.
require "omniauth/rails_csrf_protection" if defined?(OmniAuth)
