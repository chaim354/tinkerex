# OmniAuth callbacks (filled in Task 5). Stub now so devise_for's omniauthable route resolves.
module Users
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def openid_connect = redirect_to(new_user_session_path, alert: "SSO not configured.")
    def failure        = redirect_to(new_user_session_path, alert: "SSO failed.")
  end
end
