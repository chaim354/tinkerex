module Projects
  # Project tasks: an ordered checklist grouped by status. Create is nested; update/destroy are
  # shallow. `taskable` is the project (polymorphic), matching Maker::Task's contract.
  #
  # EVERY ACTION ANSWERS TWICE, and which one runs is the client's choice rather than ours:
  #
  #   turbo_stream -> replace the tasks panel only. Adding a task used to redirect to
  #     `project_path`, which re-ran the ENTIRE show action — the build log with its rich text, the
  #     Files panel, every attachment thumbnail, the sheets — and repainted the whole page, losing
  #     the scroll position, for one row appearing in a list.
  #   html -> the redirect, unchanged. This is the no-JS path and it is not a courtesy: everything
  #     the panel renders is plain form markup, so the feature works with Turbo absent.
  #
  # The panel is re-rendered SERVER-SIDE rather than patched in JavaScript, so the grouping, the
  # per-status counts and the button set stay in one place — the partial — instead of being
  # duplicated in a Stimulus controller that would then have to agree with it forever.
  class TasksController < ApplicationController
    before_action :authenticate_user!

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      next_pos = (project.tasks.maximum(:position) || -1) + 1
      task = project.tasks.new(task_params.merge(user: current_user, position: next_pos))
      if task.save
        render_tasks(project, notice: "Task added.")
      else
        render_tasks(project, alert: task.errors.full_messages.to_sentence)
      end
    end

    # ONE VALIDATED WRITE, with the completed_at stamp derived IN MEMORY from the same params it is
    # persisted with — so the refusal is total and the invalid pair is unrepresentable rather than
    # merely unlikely. This was three APIs in one action (`complete!` bang, `update` silent-false,
    # `update_column` no-validation) and both branches were wrong:
    #
    #   the else branch decided from the PARAMS, not the record, so a write the model REFUSED still
    #     ran `update_column(:completed_at, nil)` — persisting `status="done", completed_at=NULL`,
    #     which no sanctioned path can produce, by the one API that skips validation to get there;
    #   the done branch committed `complete!` first and could then fail the second write, marking a
    #     task done while it kept the title the user was replacing.
    #
    # Both were invisible to a green suite: every existing status test sends a VALID status, so
    # `update` always succeeded and the guard never ran for the reason it exists (§14e).
    # `Time.current`, not v1's `completed_at ||=`, reproduces `Maker::Task#complete!` exactly — this
    # is not a fourth spelling of the derivation rule.
    def update
      task  = project_task!(params[:id])
      attrs = task_params.to_h
      case attrs["status"]
      when nil, ""  then nil                                   # no status change: leave the stamp alone
      when "done"   then attrs["completed_at"] = Time.current
      else               attrs["completed_at"] = nil           # out of done: drop the stale stamp
      end
      if task.update(attrs)
        render_tasks(task.taskable)
      else
        # Same reason `create` passes one: a turbo_stream response replaces the panel and nothing
        # else, so without this the user presses a button, watches the panel redraw unchanged, and
        # is told nothing. `render_tasks` re-queries, so the panel shows the persisted row.
        render_tasks(task.taskable, alert: task.errors.full_messages.to_sentence)
      end
    end

    def destroy
      task = project_task!(params[:id])
      project = task.taskable
      task.destroy!
      render_tasks(project, notice: "Task deleted.")
    end

    private

    # THE ONE RESPONDER, because three actions answering the same two ways is three places to get
    # the stream target wrong. `@project`/`@tasks` are ivars rather than locals so the partial is
    # byte-identical to the one ProjectsController#show renders — a second, locals-taking copy is
    # how the two would drift.
    #
    # `@task_error` rather than `flash.now[:alert]`: a turbo_stream response replaces the tasks
    # panel and NOTHING ELSE, so a flash set here would be drawn by no response at all — the user
    # would submit an invalid task, watch the panel redraw unchanged, and be told nothing. The
    # partial renders it inline. The html branch below still uses a real flash, because there the
    # layout is re-rendered and there is something to draw it.
    def render_tasks(project, notice: nil, alert: nil)
      respond_to do |format|
        format.turbo_stream do
          @project = project
          @tasks = project.tasks.order(:position, :created_at).to_a
          @task_error = alert
          render turbo_stream: turbo_stream.replace("project-tasks", partial: "projects/tasks")
        end
        format.html { redirect_to project_path(project), notice:, alert: }
      end
    end

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
