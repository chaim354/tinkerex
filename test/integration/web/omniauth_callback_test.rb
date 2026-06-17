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
  end
end
