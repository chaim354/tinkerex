# OmniAuth SEAM (docs/parity-roadmap.md §A "keep the OmniAuth seam open"). This is the
# mountable callback endpoint a later OIDC/SSO provider plugs into — NO provider is wired
# yet (no hosted-IdP deps; CLAUDE.md §9). To enable, e.g.:
#
#   1. Add `gem "omniauth"` (MIT) + a strategy (e.g. `omniauth_openid_connect`, MIT).
#   2. Configure the provider middleware in `config/initializers/omniauth.rb`.
#   3. Route `get/post "/auth/:provider/callback"` here (the route is already drawn,
#      guarded by `OMNIAUTH_ENABLED`).
#
# The callback's job is only to authenticate the HUMAN session. The device-token +
# DevicePairing bootstrap underneath is untouched: once `log_in` succeeds, the unchanged
# flow runs (first device → register; Nth device → mint a pairing code).
class OmniauthCallbacksController < ApplicationController
  include WebAuthentication

  # GET/POST /auth/:provider/callback
  def create
    auth = request.env["omniauth.auth"]
    return redirect_to(login_path, alert: "Single sign-on is not configured.") if auth.blank?

    user = User.from_omniauth(auth)
    log_in(user)
    redirect_to files_path, notice: "Signed in via #{params[:provider]}."
  rescue => e
    Rails.logger.warn("OmniAuth callback failed: #{e.class}: #{e.message}")
    redirect_to login_path, alert: "Single sign-on failed."
  end

  def failure
    redirect_to login_path, alert: "Single sign-on was cancelled or failed."
  end
end
