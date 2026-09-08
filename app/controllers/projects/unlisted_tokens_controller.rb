module Projects
  # POST /projects/:project_id/unlisted_token — mint a new unlisted link and break the old one
  # (stage 4, S4-4; story 5.8). Session-authed web layer (§14d).
  #
  # `mint_unlisted_token` only ever FILLED a nil column (`||=`, so that a link already handed out
  # survives unlisted → public → unlisted), which meant a link handed out once worked forever with
  # no way to withdraw it. This is the way: one verb, no id, the project page as its only surface.
  class UnlistedTokensController < ApplicationController
    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      unless project.unlisted?
        return redirect_to project_path(project),
                           alert: "Only an unlisted project has a link to replace."
      end

      # `update!`, NOT `update_column`. The callback that fills this column is a `||=` on a nil, so
      # it cannot interfere; what `update!` buys is the validations — a row that has drifted into an
      # unpublishable state must not be quietly written past on its way to a new credential.
      project.update!(unlisted_token: SecureRandom.hex(16))
      redirect_to project_path(project),
                  notice: "New unlisted link. Anyone holding the old one will no longer work."
    end
  end
end
