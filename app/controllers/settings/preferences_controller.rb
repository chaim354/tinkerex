module Settings
  # THE ONE PREFERENCE THAT CHANGES WHERE FILES LAND, so it gets a door of its own rather than
  # riding Devise's account form (which demands `current_password` — the same argument
  # HandlesController makes next door: a preference is not a credential).
  #
  # Session-authed web layer (§14d).
  class PreferencesController < ApplicationController
    include CurrentProject

    # THE SELECTION IS CARRIED ACROSS THE SWITCH, WHICH IS THE WHOLE OF WHY THIS IS NOT A ONE-LINE
    # `update`. Reading the current project BEFORE the flag flips reads the OLD store; writing it
    # after the flip writes the NEW one. Without that, a maker who turns remembering on loses the
    # project they had selected this session, and one who turns it off loses the project they had
    # selected for good — a settings toggle that silently changes where the next upload goes is
    # exactly the surprise this whole slice exists to remove.
    def update
      carried = current_project&.id
      current_user.update!(remember_current_project: remembering?)
      # `current_project_id=` now resolves to the OTHER store, so this lands where reads will look.
      self.current_project_id = carried

      redirect_to settings_path, notice: notice_for(remembering?)
    end

    private

    # A checkbox posts "1"/"0"; anything else is a malformed submit and means "leave it on", the
    # default, rather than silently opting the maker out of persistence.
    def remembering? = params[:remember_current_project].to_s != "0"

    def notice_for(remembering)
      if remembering
        "Your current project will be remembered between sessions."
      else
        "Your current project will reset when you sign out."
      end
    end
  end
end
