module Models
  # A MODEL'S PROJECTS (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md).
  #
  # ATTACH IS A LINK, NEVER A MOVE: Maker::AttachToProject#attach_model writes the model's live files
  # as the project's attachment rows — the bundle path a model's FILE already took from the file page
  # — so the model stays where it is and can be in several projects. The project page derives its
  # Models panel from those rows (Maker::ProjectModels).
  #
  # DETACH DELETES THIS PROJECT'S ROWS FOR THE MODEL'S FILES AND NOTHING ELSE: no file moves, nothing
  # leaves the library, the model and its own rows are untouched. A row the maker attached by hand
  # before the model owned that file goes with it — the same rule attaching uses.
  #
  # Both ends post here: the model's "Attach to project" (models/_projects) and the project page's
  # picker (projects/models/new, `return_to=project`). HTML only — no caller wants JSON.
  class ProjectsController < ApplicationController
    before_action :set_model

    # POST /models/:model_id/projects { project_id (slug), return_to? }
    def create
      project = current_user.maker_projects.find_by!(slug: params.require(:project_id).to_s)
      if project.status == "archived"
        return redirect_back_or_to(model_path(@model),
                                   alert: "#{project.name} is archived — unarchive it to attach models.")
      end

      result = Maker::AttachToProject.new(user: current_user, project:).attach_model(@model)
      if result.relocation == :empty_model
        return redirect_back_or_to(model_path(@model), alert: "That model has no files to attach.")
      end

      notice = result.created ? "Attached #{@model.title} to #{project.name}." : "#{@model.title} is already in #{project.name}."
      if params[:return_to] == "project"
        redirect_to project_path(project, anchor: "models"), notice:
      else
        redirect_back_or_to model_path(@model), notice:
      end
    end

    # DELETE /models/:model_id/projects/:id (the project's slug)
    def destroy
      project = current_user.maker_projects.find_by!(slug: params[:id].to_s)
      # THE TABLE, NOT `project.file_attachments`: that association carries an `order(:position)`
      # scope, and a DELETE … ORDER BY is not portable. No callbacks to lose — Maker::FileAttachment
      # has none (Maker::AttachToProject#attach_bundle's insert_all relies on the same fact).
      #
      # `attachable_type` IS NOT REDUNDANT WITH `attachable_id`: a project and a model can share an
      # id, and without the type this would delete the model's OWN rows for the same files.
      removed = current_user.maker_file_attachments
                            .where(attachable_type: "Maker::Project", attachable_id: project.id,
                                   node_id: @model.file_attachments.pluck(:node_id))
                            .delete_all
      # THE COUNT, NOT A BLIND "Detached": a stale page or a second click deletes nothing, and
      # saying it did would be the one false notice on this door.
      notice = removed.zero? ? "#{@model.title} wasn't in #{project.name}." : "Detached #{@model.title} from #{project.name}."
      redirect_back_or_to project_path(project), notice:
    end

    private

    def set_model
      @model = current_user.maker_models.find_by!(slug: params[:model_id].to_s)
    end
  end
end
