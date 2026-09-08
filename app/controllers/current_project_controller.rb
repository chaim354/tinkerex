# Sets or clears the session-scoped current project (spec §3.2). Session-authed like the rest of the
# web UI. Never stores an id that isn't the user's own project.
class CurrentProjectController < ApplicationController
  # PATCH /current_project { project_id }. A present, owned id becomes current; a blank id clears (so
  # the top-bar "— none —" option flows through here too); a foreign/unknown id is ignored.
  #
  # EVERY BRANCH SAYS WHAT HAPPENED (stage 4, S4-6; story 1.5). This action changed where a
  # maker's next upload would land and redirected silently, on all three branches.
  def update
    id = params[:project_id].presence
    if id.nil?
      session.delete(:current_project_id)
      redirect_back_or_to files_path, notice: current_project_notice(nil)
    elsif (project = current_user.maker_projects.where.not(status: "archived").find_by(id: id))
      # archived projects can't be current — the read side (CurrentProject#current_project) filters them too
      session[:current_project_id] = project.id
      redirect_back_or_to files_path, notice: current_project_notice(project)
    else
      # NOT CLEARED, AND NOT NAMED. This branch has always fallen through leaving the session
      # untouched, which is right: a stale <option> or a forged id must not knock out a working
      # choice. The message names neither ownership nor existence — "that project is not yours"
      # would disclose that the id exists — and it is an ALERT, because nothing happened.
      redirect_back_or_to files_path,
                          alert: "That project isn't available — it may be archived or gone. " \
                                 "Your current project is unchanged."
    end
  end

  # DELETE /current_project — the explicit clear (top-bar "×" / project-page "Clear").
  def destroy
    session.delete(:current_project_id)
    redirect_back_or_to files_path, notice: current_project_notice(nil)
  end
end
