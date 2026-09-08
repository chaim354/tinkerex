module Settings
  # THE HANDLE CLAIM, ON ITS OWN FORM AND ITS OWN ROUTE. It lives on the Account page
  # (users/registrations/edit) but NOT in Devise's own update form, because that form demands
  # `current_password` and a handle is not a credential -- folding it in would make claiming one
  # require re-typing a password.
  #
  # Session-authed web layer (§14d), so ApplicationController and its signed-in requirement.
  class HandlesController < ApplicationController
    # ALWAYS A REDIRECT, NEVER A RE-RENDER: the form's only field is the handle, so the whole of an
    # error fits in a flash and there is no half-filled page to preserve.
    #
    # `current_user.handle = ...` then `save`, rather than `update`, because a blank field must
    # CLEAR the handle -- `normalizes` turns "" into nil -- and the lock validation is what refuses
    # that while a project is published. Assigning first also means the invalid value is still on
    # the object when `errors` is read.
    def update
      current_user.handle = params.require(:user).permit(:handle)[:handle]
      if current_user.save
        redirect_to return_path, notice: "Your handle is @#{current_user.handle}."
      else
        redirect_to return_path, alert: "Handle #{current_user.errors[:handle].first}."
      end
    end

    # WHERE A CLAIM RETURNS TO (stage 4, S4-4). The Publish panel claims a handle inline, and
    # bouncing a maker to the Account page mid-publish loses the thing they were doing. The param
    # is a project SLUG, not a path: it is looked up in `current_user`'s own projects and turned
    # into a route here, so an unknown or someone else's slug falls back to the Account page rather
    # than redirecting anywhere a caller named. There is no URL in this parameter to sanitise.
    def return_path
      # A STRING OR NOTHING. `params[:project_id]` can arrive as a hash or an array; `find_by(slug:)`
      # on a hash raises TypeError, and this runs AFTER `current_user.save` — so a mis-shaped param
      # was a 500 on a claim that had already succeeded (found in review). Not a String means "no
      # project named", the same fallback as an unknown slug.
      slug = params[:project_id]
      slug = nil unless slug.is_a?(String) && slug.present?
      project = slug && current_user.maker_projects.find_by(slug:)
      project ? project_path(project) : edit_user_registration_path
    end
    private :return_path
  end
end
