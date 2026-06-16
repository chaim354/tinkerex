# Devise OmniAuth callbacks. The callback authenticates the HUMAN web session only; the
# device-token + device-login enrollment underneath is untouched. from_omniauth carries the
# anti-takeover guard (AccountLinkRefused).
module Users
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def openid_connect
      auth = request.env["omniauth.auth"]
      return fail_sso("Single sign-on is not configured.") if auth.blank?

      user = User.from_omniauth(auth)
      sign_in(user, event: :authentication)
      redirect_to files_path, notice: "Signed in via #{auth.provider}."
    rescue User::AccountLinkRefused
      fail_sso("That email is already linked to an account. Sign in with your password.")
    rescue => e
      Rails.logger.warn("OmniAuth callback failed: #{e.class}: #{e.message}")
      fail_sso("Single sign-on failed.")
    end

    def failure
      fail_sso("Single sign-on was cancelled or failed.")
    end

    private

    def fail_sso(msg)
      redirect_to new_user_session_path, alert: msg
    end
  end
end
