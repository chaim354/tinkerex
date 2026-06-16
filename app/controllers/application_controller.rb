class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :web_device

  # After a Devise sign-in (or sign-up confirmation), land on the file library — the app's
  # home surface — matching the pre-Devise behavior. (Devise's default is root_path, which
  # redirects to /files anyway; this skips the extra hop and keeps redirects explicit.)
  def after_sign_in_path_for(_resource)
    files_path
  end

  # A stable, reusable Device for the signed-in web user. Lets the web UI mint per-user
  # presigned URLs and record commits through the SAME machinery as the desktop client —
  # the device-token bootstrap is unchanged; the web session just reuses it (CLAUDE.md §8).
  WEB_DEVICE_NAME = "web-session".freeze

  def web_device
    return unless user_signed_in?
    @web_device ||= current_user.devices.find_by(name: WEB_DEVICE_NAME) ||
                    Device.register!(user: current_user, name: WEB_DEVICE_NAME)
  end
end
