module Projects
  # Project tasks: an ordered checklist grouped by status. Create is nested; update/destroy are
  # shallow. `taskable` is the project (polymorphic), matching Maker::Task's contract.
  class TasksController < ApplicationController
    before_action :authenticate_user!

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      next_pos = (project.tasks.maximum(:position) || -1) + 1
      task = project.tasks.new(task_params.merge(user: current_user, position: next_pos))
      if task.save
        redirect_to project_path(project), notice: "Task added."
      else
        redirect_to project_path(project), alert: task.errors.full_messages.to_sentence
      end
    end

    def update
      task = project_task!(params[:id])
      new_status = task_params[:status]
      # Route "done" through the model op so completed_at is stamped consistently.
      if new_status == "done" && task.status != "done"
        task.complete!
        task.update(task_params.except(:status))
      else
        task.update(task_params)
        # Moving OUT of done: drop the stale completion timestamp.
        task.update_column(:completed_at, nil) if new_status.present? && new_status != "done" && task.completed_at
      end
      redirect_to project_path(task.taskable)
    end

    def destroy
      task = project_task!(params[:id])
      project = task.taskable
      task.destroy!
      redirect_to project_path(project), notice: "Task deleted."
    end

    private

    # This controller manages PROJECT tasks only. Scoping the lookup to a project-taskable task
    # (not just current_user's tasks) keeps `project_path(task.taskable)` well-formed: a user's
    # Item-scoped or unscoped task reached through the shallow /tasks/:id route is a 404 here, not
    # a redirect to a nonexistent /projects/<item> (404) or `project_path(nil)` (a 500).
    def project_task!(id)
      current_user.maker_tasks.where(taskable_type: "Maker::Project").find(id)
    end

    def task_params
      params.require(:task).permit(:title, :status, :notes)
    end
  end
end
