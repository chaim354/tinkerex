module Projects
  # Build-log entries for a project. Create is nested under a project; destroy is shallow.
  class BuildLogEntriesController < ApplicationController
    before_action :authenticate_user!

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      entry = project.build_log_entries.new(entry_params.merge(user: current_user))
      if entry.save
        redirect_to project_path(project), notice: "Log entry added."
      else
        redirect_to project_path(project), alert: entry.errors.full_messages.to_sentence
      end
    end

    def destroy
      entry = current_user.maker_build_log_entries.find(params[:id])
      project = entry.project
      entry.destroy!
      redirect_to project_path(project), notice: "Entry deleted."
    end

    private

    def entry_params
      params.require(:build_log_entry).permit(:body, :entry_type)
    end
  end
end
