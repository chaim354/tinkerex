# Sets or clears the session-scoped current project (spec §3.2). Session-authed like the rest of the
# web UI. Never stores an id that isn't the user's own project.
class CurrentProjectController < ApplicationController
  before_action :authenticate_user!

  # PATCH /current_project { project_id }. A present, owned id becomes current; a blank id clears (so
  # the top-bar "— none —" option flows through here too); a foreign/unknown id is ignored.
  def update
    id = params[:project_id].presence
    if id.nil?
      session.delete(:current_project_id)
    elsif (project = current_user.maker_projects.find_by(id: id))
      session[:current_project_id] = project.id
    end
    redirect_back fallback_location: files_path
  end

  # DELETE /current_project — the explicit clear (top-bar "×" / project-page "Clear").
  def destroy
    session.delete(:current_project_id)
    redirect_back fallback_location: files_path
  end
end
