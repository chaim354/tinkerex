# /help: what the library is, what a Projects/ folder turns into, why a tool can be missing, and
# how accounts work, in the maker's words (onboarding, 2026-10-13). Session-authed like every page
# here: ApplicationController's `authenticate_user!` is the default-deny, and a page that explains
# a library has no business being shown to someone who cannot open one. The copy that differs per
# backend asks `capabilities`, never an adapter class or LIBRARY_BACKEND, so the view needs nothing
# from this action.
class HelpController < ApplicationController
  # Reachable before the library folder is confirmed (K): the first-run screen links here, and an
  # explanation of what a library is must not bounce back to the question it explains.
  skip_before_action :require_library_folder!

  def show; end
end
