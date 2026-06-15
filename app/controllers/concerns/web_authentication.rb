# =============================================================================
# PLACEHOLDER WEB AUTH — REPLACE WHEN REAL AUTH IS CHOSEN
# =============================================================================
# This is a deliberately minimal, swappable session seam for the MVP web UI. It is
# NOT real authentication: there is no password, no email verification — a dev "login"
# just selects an existing User by email and stores its id in the session.
#
# The rest of the web layer only depends on `current_user` / `require_login!` /
# `web_device` here, so when the real auth workstream lands (OAuth/OIDC — see
# CLAUDE.md §8/§12 step 5) it can replace the body of these methods (or this whole
# concern) without touching the file controllers.
#
# Under the hood each web user gets a single reusable "web session" Device so the web
# UI can reuse the EXACT same per-user presign / ownership-gated paths the desktop
# client uses (chunk keys are scoped chunks/<user_id>/<hash>). The web device is an
# implementation detail of this seam.
# =============================================================================
module WebAuthentication
  extend ActiveSupport::Concern

  included do
    helper_method :current_user, :logged_in? if respond_to?(:helper_method)
  end

  private

  def current_user
    @current_user ||= User.find_by(id: session[:web_user_id])
  end

  def logged_in? = current_user.present?

  def require_login!
    redirect_to login_path, alert: "Please sign in to continue." unless logged_in?
  end

  # PLACEHOLDER: sign in as an existing user (no password). Real auth replaces this.
  def log_in(user)
    reset_session
    session[:web_user_id] = user.id
    @current_user = user
  end

  def log_out
    reset_session
    @current_user = nil
  end

  # A stable, reusable Device for this web user. Lets the web UI mint per-user
  # presigned URLs and record commits through the SAME machinery as the desktop client.
  WEB_DEVICE_NAME = "web-session".freeze

  def web_device
    @web_device ||= current_user.devices.find_by(name: WEB_DEVICE_NAME) ||
                    Device.register!(user: current_user, name: WEB_DEVICE_NAME)
  end
end
