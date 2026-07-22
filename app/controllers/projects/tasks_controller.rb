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
      task = current_user.maker_tasks.find(params[:id])
      # Route "done" through the model op so completed_at is stamped consistently.
      if task_params[:status] == "done" && task.status != "done"
        task.complete!
        task.update(task_params.except(:status))
      else
        task.update(task_params)
      end
      redirect_to project_path(task.taskable)
    end

    def destroy
      task = current_user.maker_tasks.find(params[:id])
      project = task.taskable
      task.destroy!
      redirect_to project_path(project), notice: "Task deleted."
    end

    private

    def task_params
      params.require(:task).permit(:title, :status, :notes)
    end
  end
end
