module Projects
  # The project page's own panel layout: show/hide, reorder, reset (stage 4, S4-7; story 6.5).
  #
  # IT WRITES ONLY KEYS FROM Maker::Project::PANELS, and that is structural rather than a
  # validation someone can loosen: every array below is intersected with that constant before it
  # reaches the column, so a crafted request cannot put `../../etc/passwd` in the stored order and
  # projects/show.html.erb's `render "projects/#{key}"` can never be handed a partial name that
  # does not exist. Maker::ProjectKind.layout_for filters again on the way OUT, for the rows this
  # door did not write (the v1 API, a console, a later migration) — two filters, one at each end,
  # because only the read one cannot be bypassed.
  #
  # ONE PATCH, TWO SHAPES. `?move=up` reorders and carries no `panels` key at all, so the branch is
  # taken BEFORE `params.require(:panels)` — a move must not 400 on a key it never sends.
  #
  # EVERY RESPONSE REDIRECTS BACK TO THE PAGE WITH THE RE-OPEN HINT. The chooser is a <details> and
  # this is a full page reload with no JavaScript anywhere, so without the hint every click would
  # close it and the maker would reopen it to click again. It is a render hint, not state
  # (ProjectsController#show reads it into @panels_open) — the same shape as `?scanning=1`.
  class PanelsController < ApplicationController
    before_action :set_project

    def update
      attrs = params[:move].present? ? moved : chosen
      # A MOVE THAT MOVED NOTHING WRITES NOTHING (found in review): an edge move or a direction the
      # buttons never send used to materialise the column as today's layout, which is harmless for
      # `other` and the freezing mechanism below for every other kind.
      @project.update!(panels: attrs) if attrs
      redirect_to back_to_panels, notice: "Panels updated."
    end

    # RESET MEANS REMOVE THE OVERRIDE, not "write the current preset into the column": the second
    # would freeze this release's defaults onto the row and stop the project following its own kind
    # — including after the maker changes that kind on the edit form.
    def destroy
      @project.update!(panels: nil)
      redirect_to back_to_panels,
                  notice: "Panels reset to the #{Maker::ProjectKind.label(@project.kind)} defaults."
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end

    def back_to_panels = project_path(@project, panels: "open", anchor: "panels")

    # A MOVE REWRITES THE FULL ORDER, HIDDEN PANELS INCLUDED, so a panel that is currently hidden
    # keeps its slot rather than collapsing to the end the moment it is shown again — which is also
    # why the chooser lists every key rather than only the visible ones.
    #
    # AN UNKNOWN PANEL OR AN EDGE MOVE IS A NO-OP, NEVER AN ERROR: the buttons are rendered from
    # the same list this reads, so the only way to reach either is a hand-made request, and a
    # redirect that changed nothing is the honest answer to one.
    def moved
      layout = @project.panel_layout
      order = layout.order.dup
      from = order.index(params[:panel].to_s)
      # "up" and "down" are the only directions; anything else is a hand-made request and moves
      # nothing (found in review: any other value read as "down").
      step = { "up" => -1, "down" => 1 }[params[:move].to_s]
      to = from && step && from + step
      return nil unless from && to&.between?(0, order.size - 1)

      order[from], order[to] = order[to], order[from]
      # ONLY THE QUESTION THAT WAS ASKED. A move writes the ORDER; the hidden set rides along only
      # when the row already carries one. Copying the kind's preset into the column would freeze it
      # there — a maker who later changes the kind on the edit form would keep the OLD kind's hidden
      # panels (found in review: one reorder click on a laser project did exactly that, and
      # switching to electronics left BOM and Wiring hidden). #destroy's rule, applied to moves.
      stored = @project.panels.is_a?(Hash) ? @project.panels : {}
      { "order" => order }.merge(stored.slice("hidden"))
    end

    # THE FORM SENDS THE COMPLETE PICTURE: `order` is every panel in the order they were shown, and
    # `visible` is the checked subset, so hidden is simply the difference. An unchecked checkbox
    # sends NOTHING, which is exactly why `order` is a list of hidden fields rather than something
    # derived from `visible` — without it, unchecking a box would delete the panel from the order
    # instead of hiding it.
    def chosen
      attrs = params.require(:panels).permit(order: [], visible: [])
      order = (known(attrs[:order]) + @project.panel_layout.order) & Maker::Project::PANELS
      { "order" => order, "hidden" => order - known(attrs[:visible]) }
    end

    def known(list) = Array(list).map(&:to_s) & Maker::Project::PANELS
  end
end
