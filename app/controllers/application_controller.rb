class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # DEFAULT-DENY: the web app is session-authed (CLAUDE.md §14d), so a new subclass is private
  # from the moment it exists rather than from whenever someone remembers the line. Enforced by
  # test/architecture_invariants_test.rb, which reads the callback chain of every descendant.
  #
  # THE `unless:` IS MANDATORY, NOT DEFENSIVE. `Devise.parent_controller` defaults to
  # "ApplicationController", so DeviseController and its eleven subclasses inherit this callback
  # — and a bare `before_action :authenticate_user!` makes /users/sign_in redirect to itself.
  # It fails LOUD, not silently: auth_pages_test.rb's five anonymous GETs and
  # account_enumeration_test.rb's three anonymous POSTs are what pin this arm, because the
  # invariants guard excludes Devise controllers by construction and structurally cannot see it.
  #
  # Placed immediately after `allow_browser` so the chain index is unchanged from when the
  # sixteen subclasses each declared it: `require_capability!`, `require_scannable!`,
  # `set_project`, `load_addon` and `set_model` all still run AFTER auth, since a parent's
  # callbacks run before a child's.
  #
  # Does NOT reach ActiveStorage::BaseController (an ActionController::Base descendant) — the
  # direct_uploads hole in §15 is closed by the route shadow, not by this.
  before_action :authenticate_user!, unless: :devise_controller?

  include CurrentProject

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
