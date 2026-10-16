# THE MARKETING LANDING (2026-10-16): what a stranger sees at `/` on the public demo's box, and nowhere
# else (config/routes.rb asks Tinkerex::Landing.enabled?). It stands on ActionController::Base, NOT
# ApplicationController, for the reason Public::BaseController does: every ApplicationController
# descendant must run `authenticate_user!` (architecture_invariants_test.rb), and the honest way to have
# a page nobody signs in to see is to stand outside that tree, never to skip the callback. It is NOT in
# the Public namespace either, because its Try the demo button is a form whose CSRF token writes the
# session, which `Public::` may never touch (§14d). It reads no user: the route only reaches it signed out.
class LandingsController < ActionController::Base
  layout "application"

  def show
    # One COUNT, the one the sign-in card pays (Tinkerex::Demo.available?): the demo button exists only
    # while there is an account to sign into, and Install takes the accent when there is none.
    @demo_available = Tinkerex::Demo.available?
  end
end
