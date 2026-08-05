module Tools
  # Shared base for every addon's web UI. Session-authed like the rest of the web app.
  class BaseController < ApplicationController
    before_action :authenticate_user!

    # HERE RATHER THAN IN THE TWO SAVE DOORS, because every addon door writes through
    # Maker::Addons::LibraryOutput into a folder the save dialog defaults to the CURRENT PROJECT's —
    # so needing the eager nudge is a property of being an addon door, not of these two in
    # particular. The concern is private methods only (no before_action, no filters), so an addon
    # controller that never writes anything pays nothing for it.
    #
    # WHAT THIS DOES NOT DO, stated so it is not mistaken for a guarantee: including the concern
    # does not CALL it. A future addon door still has to invoke #intake_project_folder after its
    # write, and forgetting to is exactly the "an EIGHTH door silently skips the rule" shape §14f
    # names. This removes the excuse, not the requirement.
    include ProjectFolderIntake
  end
end
