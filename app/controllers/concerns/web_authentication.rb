# =============================================================================
# WEB AUTH — real Rails 8 session-based authentication
# =============================================================================
# Replaces the old placeholder (email-only, no password) dev seam. Identity is now
# proven by a password (has_secure_password) + email confirmation; a login creates a
# server-side `Session` row keyed by a signed, http-only cookie holding only the
# session token (digest-at-rest). `current_user` resolves that session.
#
# This is the HUMAN-identity layer (docs/parity-roadmap.md §A). It sits *in front of*
# the device-token + DevicePairing bootstrap (v1 API), which is UNCHANGED — the web UI
# still gets a per-user `web_device` for the same per-user presign / ownership paths the
# desktop client uses. The file controllers depend only on `current_user` /
# `require_login!` / `web_device` here, so the auth mechanism swapped without touching
# them.
# =============================================================================
module WebAuthentication
  extend ActiveSupport::Concern

  SESSION_COOKIE = :session_token

  included do
    helper_method :current_user, :logged_in? if respond_to?(:helper_method)
  end

  private

  def current_session
    return @current_session if defined?(@current_session)
    token = cookies.signed[SESSION_COOKIE]
    @current_session = Session.authenticate(token)
  end

  def current_user
    @current_user ||= current_session&.user
  end

  def logged_in? = current_user.present?

  def require_login!
    redirect_to login_path, alert: "Please sign in to continue." unless logged_in?
  end

  # Establish a real login: start a server-side Session and set the signed cookie. Only
  # confirmed users should reach here (email-ownership gate — §12 step 5); the sessions
  # controller enforces `user.confirmed?` before calling this.
  def log_in(user)
    reset_session
    session = Session.start!(user:, user_agent: request.user_agent, ip_address: request.remote_ip)
    cookies.signed.permanent[SESSION_COOKIE] = {
      value: session.plaintext_token, httponly: true, same_site: :lax,
      secure: Rails.env.production?
    }
    @current_session = session
    @current_user = user
  end

  def log_out
    current_session&.destroy
    cookies.delete(SESSION_COOKIE)
    reset_session
    @current_session = nil
    @current_user = nil
  end

  # A stable, reusable Device for this web user. Lets the web UI mint per-user
  # presigned URLs and record commits through the SAME machinery as the desktop client.
  # The device bootstrap layer is unchanged — this just reuses it (CLAUDE.md §8).
  WEB_DEVICE_NAME = "web-session".freeze

  def web_device
    @web_device ||= current_user.devices.find_by(name: WEB_DEVICE_NAME) ||
                    Device.register!(user: current_user, name: WEB_DEVICE_NAME)
  end
end
