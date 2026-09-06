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
        redirect_to edit_user_registration_path, notice: "Your handle is @#{current_user.handle}."
      else
        redirect_to edit_user_registration_path, alert: "Handle #{current_user.errors[:handle].first}."
      end
    end
  end
end
