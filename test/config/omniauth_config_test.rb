require "test_helper"

# Wiring-level guarantees for the OIDC seam (config/initializers/omniauth.rb +
# the omniauth_openid_connect gem). These are NOT the from_omniauth behavior tests
# (see test/models/user_omniauth_test.rb) — they prove the strategy is actually
# loaded and the provider config degrades cleanly when no OIDC env is set.
class OmniauthConfigTest < ActiveSupport::TestCase
  # The gem is now `require`d (not `require: false`), so Devise's
  # `config.omniauth :openid_connect` has a real strategy class to register.
  test "the OpenIDConnect strategy class is loaded at boot" do
    assert defined?(OmniAuth::Strategies::OpenIDConnect),
           "omniauth_openid_connect must be required so the strategy registers"
  end

  # Devise declares omniauth_providers on the User model, so the request/callback
  # routes are mounted regardless of whether a provider is configured. This is the
  # "degrade cleanly" contract: routes exist; the request phase just fails (handled
  # by the callbacks controller) when no provider env is present.
  test "the openid_connect callback route is always mounted" do
    assert Rails.application.routes.url_helpers
                .respond_to?(:user_openid_connect_omniauth_callback_path),
           "the OIDC callback route must be mounted from the model's omniauth_providers"
  end

  # The guard the initializer uses to decide whether to register the provider.
  test "oidc_configured? requires issuer + client id + secret" do
    with_env("OIDC_ISSUER" => nil, "OIDC_CLIENT_ID" => nil, "OIDC_CLIENT_SECRET" => nil) do
      assert_not OmniauthConfig.oidc_configured?, "no env -> not configured (boots inert)"
    end
    with_env("OIDC_ISSUER" => "https://idp.example", "OIDC_CLIENT_ID" => "cid",
             "OIDC_CLIENT_SECRET" => nil) do
      assert_not OmniauthConfig.oidc_configured?, "a missing secret -> not configured"
    end
    with_env("OIDC_ISSUER" => "https://idp.example", "OIDC_CLIENT_ID" => "cid",
             "OIDC_CLIENT_SECRET" => "sec") do
      assert OmniauthConfig.oidc_configured?, "all three present -> configured"
    end
  end

  test "oidc_scope defaults to openid+email and is overridable via OIDC_SCOPE" do
    with_env("OIDC_SCOPE" => nil) do
      assert_equal %i[openid email], OmniauthConfig.oidc_scope
    end
    with_env("OIDC_SCOPE" => "openid email profile") do
      assert_equal %i[openid email profile], OmniauthConfig.oidc_scope
    end
  end

  private

  def with_env(vars)
    old = vars.transform_values { |_| nil }
    vars.each_key { |k| old[k] = ENV[k] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
