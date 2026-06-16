require "test_helper"

module Web
  # OmniAuth callback in mock mode (no live IdP). Verifies a new OAuth login creates an
  # account + session, and the anti-takeover guard surfaces as a generic SSO failure.
  class OmniauthCallbackTest < ActionDispatch::IntegrationTest
    setup do
      OmniAuth.config.test_mode = true
      OmniAuth.config.logger = Rails.logger
    end
    teardown do
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:openid_connect] = nil
    end

    def mock(email:, uid: "u-1", verified: true)
      OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new(
        provider: "openid_connect", uid: uid,
        info: { email: email, email_verified: verified }
      )
      Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:openid_connect]
    end

    test "a new OAuth login creates an account and signs in" do
      mock(email: "newoauth@example.com")
      assert_difference -> { User.count }, 1 do
        get user_openid_connect_omniauth_callback_path
      end
      assert_redirected_to files_path
    end

    test "OAuth refusing to take over a password account fails generically" do
      User.create!(email: "victim@example.com", password: "correct horse battery staple",
                   confirmed_at: Time.current)
      mock(email: "victim@example.com", uid: "u-evil", verified: true)
      assert_no_difference -> { User.count } do
        get user_openid_connect_omniauth_callback_path
      end
      assert_redirected_to new_user_session_path
      assert_match(/already linked/i, flash[:alert])
    end

    test "the sign-in page renders without an SSO button when no OIDC env is set" do
      with_oidc_env(nil) do
        get new_user_session_path
        assert_response :success
        assert_no_match(/openid_connect/, response.body,
                        "no provider configured -> no SSO button (degrades cleanly)")
      end
    end

    test "the sign-in page renders an SSO button when OIDC env is configured" do
      with_oidc_env("OIDC_ISSUER" => "https://idp.example",
                    "OIDC_CLIENT_ID" => "cid", "OIDC_CLIENT_SECRET" => "sec") do
        get new_user_session_path
        assert_response :success
        assert_match(%r{users/auth/openid_connect}, response.body,
                     "a configured provider -> the SSO authorize button is shown")
      end
    end

    private

    # Set (or clear, with nil) the OIDC_* env around a block, restoring afterward.
    def with_oidc_env(vars)
      keys = %w[OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET]
      saved = keys.index_with { |k| ENV[k] }
      keys.each { |k| ENV.delete(k) }
      (vars || {}).each { |k, v| ENV[k] = v }
      yield
    ensure
      keys.each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v unless v.nil? }
    end
  end
end
