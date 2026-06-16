# OmniAuth/OIDC provider wiring (CLAUDE.md §8 — the human web-login layer; the v1
# device-token machinery underneath is untouched). The User model declares
# `omniauth_providers: %i[openid_connect]`, so Devise always mounts the request/callback
# ROUTES for that provider; this file configures the provider STRATEGY + credentials.
#
# DEGRADE CLEANLY: a provider is only registered when its required ENV is present. With no
# OIDC env set the app still boots — Devise mounts the routes, but hitting the request phase
# with no configured provider just fails the OmniAuth flow (handled by the callbacks
# controller's #failure), never a boot crash. We deliberately do NOT call
# `config.omniauth :openid_connect` with a nil issuer/client-id, which would crash discovery
# at request time (and, with `discovery: true`, attempt a network call to a nil issuer).
#
# Secrets live in ENV only (never committed):
#   OIDC_ISSUER         e.g. https://accounts.google.com or your self-hosted IdP issuer URL
#   OIDC_CLIENT_ID      the OAuth client / relying-party id
#   OIDC_CLIENT_SECRET  the OAuth client secret
#   OIDC_REDIRECT_URI   e.g. https://your.host/users/auth/openid_connect/callback
#   OIDC_SCOPE          optional, space-separated; defaults to "openid email" (email is
#                       required for the from_omniauth identity mapping)
#   OIDC_DISPLAY_NAME   optional human label for the sign-in button (UI only)

module OmniauthConfig
  module_function

  # All three are required to mint a working provider; redirect_uri is optional (omniauth
  # derives a default from the request when omitted, but most IdPs require an exact match,
  # so we pass it through when set).
  def oidc_configured?
    %w[OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET].all? { |k| ENV[k].present? }
  end

  def oidc_scope
    ENV["OIDC_SCOPE"].presence&.split&.map(&:to_sym) || %i[openid email]
  end
end

Devise.setup do |config|
  if OmniauthConfig.oidc_configured?
    config.omniauth :openid_connect, {
      name: :openid_connect,
      issuer: ENV["OIDC_ISSUER"],
      discovery: true, # pull authorize/token/userinfo/jwks endpoints from the issuer's .well-known
      scope: OmniauthConfig.oidc_scope,
      response_type: :code,
      uid_field: "sub", # the OIDC subject — the stable per-user id we key UserIdentity on
      client_options: {
        identifier:   ENV["OIDC_CLIENT_ID"],
        secret:       ENV["OIDC_CLIENT_SECRET"],
        redirect_uri: ENV["OIDC_REDIRECT_URI"].presence
      }.compact
    }
    Rails.logger.info("[omniauth] OpenID Connect provider configured (issuer=#{ENV['OIDC_ISSUER']})")
  else
    Rails.logger.info("[omniauth] OpenID Connect not configured (set OIDC_ISSUER/OIDC_CLIENT_ID/" \
                      "OIDC_CLIENT_SECRET to enable); SSO routes mounted but inert.")
  end
end

# CSRF protection for the OmniAuth request phase (omniauth-rails_csrf_protection, MIT) —
# requires the request-phase trigger to be a POST with an authenticity token. Loaded
# unconditionally; harmless when no provider is configured.
require "omniauth/rails_csrf_protection" if defined?(OmniAuth)
