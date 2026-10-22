# SAVED CALCULATIONS (2026-10-21; docs/superpowers/plans/2026-10-21-calculator-modal.md). Session-authed
# like every web controller (§14d) and never the v1 API. Two callers:
#
#   * THE CALCULATOR MODAL (layouts/_calculator.html.erb) loads `new` into its lazy `calculator-save`
#     frame when the maker opens Save to project, and submits it to `create`. The frame is why the
#     layout itself reads no project list: the modal renders on every signed-in page, and a select
#     of every project in the layout would be a query on every one of them.
#   * THE PROJECT PAGE'S CALCULATIONS PANEL (projects/_calculations.html.erb) renames (`update`) and
#     deletes (`destroy`) with plain forms and a redirect back — Projects::ConnectionsController's
#     idiom, because a label is edited far less often than a task is toggled.
#
# `create` ANSWERS TWICE, like Projects::TasksController: a turbo_stream replaces the modal's form
# (cleared, with what was saved and where) and the panel's rows if that project's page is the one
# open, and the html branch is the redirect. Nothing here evaluates an expression: the browser's
# engine (lib/calc.js) is the only one, and Maker::Calculation validates the SHAPE of what it sends.
class CalculationsController < ApplicationController
  # GET /calculations/new?project_id=<id> — the save form, for the frame. `project_id` is the page's
  # own project (the layout passes it on a project page), preselected; anywhere else the select asks.
  def new
    @calculation = Maker::Calculation.new(project_id: default_project_id)
    @projects = project_choices(@calculation.project_id)
    render layout: false
  end

  def create
    @calculation = current_user.maker_calculations.new(calculation_params)
    if @calculation.save
      saved = @calculation
      respond_to do |format|
        format.turbo_stream do
          @saved = saved
          @calculation = Maker::Calculation.new(project_id: saved.project_id)
          @projects = project_choices(saved.project_id)
          render turbo_stream: [
            turbo_stream.replace("calculator-save-form", partial: "calculations/form"),
            # A NO-OP UNLESS THAT PROJECT'S PAGE IS THE ONE OPEN WITH ITS PANEL ON IT. An empty
            # panel is absent (ON_DEMAND), so the first save shows up on the next visit, which the
            # saved notice links to.
            turbo_stream.replace(helpers.calculation_rows_id(saved.project),
                                 partial: "projects/calculation_rows",
                                 locals: { project: saved.project, calculations: saved.project.calculations.to_a })
          ]
        end
        format.html do
          redirect_to project_path(saved.project, anchor: "project-calculations"),
                      notice: "Saved “#{saved.label}” to #{saved.project.name}."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          @projects = project_choices(@calculation.project_id)
          render turbo_stream: turbo_stream.replace("calculator-save-form", partial: "calculations/form"),
                 status: :unprocessable_entity
        end
        format.html { redirect_back_or_to root_path, alert: @calculation.errors.full_messages.to_sentence }
      end
    end
  end

  # SCOPED TO THIS USER'S OWN ROWS, never a bare Maker::Calculation.find — a foreign id 404s (§8).
  # The label is the only thing a saved row lets you change: the expression, result and unit are a
  # record of what the calculator showed, and "Open in calculator" is how to work it again.
  def update
    calculation = current_user.maker_calculations.find(params[:id])
    if calculation.update(params.require(:calculation).permit(:label))
      redirect_back_or_to project_path(calculation.project, anchor: "project-calculations"), notice: "Renamed to “#{calculation.label}”."
    else
      redirect_back_or_to project_path(calculation.project, anchor: "project-calculations"),
                          alert: calculation.errors.full_messages.to_sentence
    end
  end

  def destroy
    calculation = current_user.maker_calculations.find(params[:id])
    project = calculation.project
    calculation.destroy!
    redirect_back_or_to project_path(project, anchor: "project-calculations"), notice: "Deleted “#{calculation.label}”."
  end

  private

  def calculation_params
    params.require(:calculation).permit(:project_id, :label, :expression, :result, :unit, :inch_fraction)
  end

  # A String naming one of this user's projects, or nil. A foreign or junk id preselects nothing
  # rather than 404ing the frame: the select then asks, and `create` would refuse the id anyway.
  def default_project_id
    id = params[:project_id]
    return nil unless id.is_a?(String) && id.match?(/\A\d+\z/)

    current_user.maker_projects.where(id: id.to_i).pick(:id)
  end

  # [name, id] pairs, most recently touched first (the sidebar's order). Archived projects are left
  # out — except the one preselected, so saving from an archived project's own page still works.
  def project_choices(selected_id)
    scope = current_user.maker_projects
    scope.where.not(status: "archived").or(scope.where(id: selected_id))
         .order(updated_at: :desc).pluck(:name, :id)
  end
end
