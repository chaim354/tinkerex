module Projects
  # The project page's own panel layout: show/hide, reorder, choose a view, reset (stage 4, S4-7;
  # story 6.5; folder panels 2026-09-08).
  #
  # IT WRITES ONLY KEYS FROM THE PROJECT'S OWN VOCABULARY, and that is structural rather than a
  # validation someone can loosen: every array below is intersected with `Maker::Project::PANELS`
  # plus this project's CURRENT depth-one folder keys before it reaches the column, so a crafted
  # request cannot put `../../etc/passwd` in the stored order and projects/show.html.erb's
  # `render "projects/#{key}"` can never be handed a partial name that does not exist.
  # Maker::ProjectKind.layout_for filters again on the way OUT, for the rows this door did not
  # write (the v1 API, a console, a later migration) — two filters, one at each end, because only
  # the read one cannot be bypassed. THE TWO FILTERS ARE NOT THE SAME LIST any more, and that is
  # fine in the one direction it can differ: a folder deleted between this write and the next read
  # drops out on the way out, which is exactly the totality the reader exists for.
  #
  # THE VOCABULARY COSTS A DIRS-ONLY LISTING (`load_files: false`) — the walk over the user's dirs
  # this project's page pays anyway, minus the files query. Without it this door knows nothing
  # about folder keys and would silently drop every one of them from an ordinary Save: a maker who
  # opened the chooser once would lose their folder panels' arrangement.
  #
  # ONE PATCH, THREE SHAPES. `view[<key>]=<view>` carries no `panels` key and neither does
  # `?move=up`, so both branches are taken BEFORE `params.require(:panels)` — a move or a view
  # toggle must not 400 on a key it never sends.
  #
  # A WRITE REDIRECTS BACK TO THE PAGE WITH THE RE-OPEN HINT, EXCEPT A VIEW TOGGLE. The chooser is
  # a <details> and this is a full page reload with no JavaScript anywhere, so without the hint
  # every click would close it and the maker would reopen it to click again. It is a render hint,
  # not state (ProjectsController#show reads it into @panels_open) — the same shape as `?scanning=1`.
  # A view toggle is not clicked in the chooser at all: it lives in the panel's own head, so it
  # returns to THAT panel's anchor and leaves the chooser alone.
  class PanelsController < ApplicationController
    before_action :set_project

    def update
      # THE VIEW BRANCH IS FIRST AND ANSWERS DIFFERENTLY: it is the only one whose result is
      # visible without looking at the chooser, so it carries no notice (the panel simply redraws
      # in the view that was asked for) and lands on the panel instead of on the chooser.
      return update_view if params[:view].present?

      attrs = params[:move].present? ? moved : chosen
      # A MOVE THAT MOVED NOTHING WRITES NOTHING (found in review): an edge move or a direction the
      # buttons never send used to materialise the column as today's layout, which is harmless for
      # `other` and the freezing mechanism below for every other kind.
      @project.update!(panels: attrs) if attrs
      redirect_to back_to_panels, notice: "Panels updated."
    end

    # RESET MEANS REMOVE THE OVERRIDE, not "write the current preset into the column": the second
    # would freeze this release's defaults onto the row and stop the project following its own kind
    # — including after the maker changes that kind on the edit form. It clears the chosen VIEWS
    # too, by the same argument: they are part of the arrangement, not a separate setting.
    def destroy
      @project.update!(panels: nil)
      redirect_to back_to_panels,
                  notice: "Panels reset to the #{Maker::ProjectKind.label(@project.kind)} defaults."
    end

    private

    # THE DIRS-ONLY LISTING IS BUILT HERE, FOR EVERY ACTION, because the vocabulary is what makes
    # `known` total and #destroy is the one action that does not need it. Building it once in the
    # filter is cheaper to read than three call sites asking for the same thing, and #destroy
    # writes nil regardless.
    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
      @listing = Maker::ProjectFolderListing.new(current_user, @project, load_files: false)
    end

    def back_to_panels = project_path(@project, panels: "open", anchor: "panels")

    # NOT MEMOIZED, for Maker::Project#panel_layout's own reason: this door writes the column and
    # could read the layout back in the same request, and a memo would answer with the layout from
    # before the write.
    def layout = @project.panel_layout(folders: @listing.panel_folders)

    def folder_keys = @listing.panel_folders.map { |node_id, _repo| Maker::ProjectKind.folder_key(node_id) }

    def vocabulary = Maker::Project::PANELS + folder_keys

    # ONE PANEL'S VIEW (2026-09-08, folder panels; spec decision 6). The pair is validated on BOTH
    # sides — the key against this project's vocabulary, the value against Maker::Project::VIEWS —
    # and an invalid pair writes NOTHING rather than raising: `view` is a hand-writable param like
    # every other one this door takes, and the buttons that send it are rendered from the same two
    # lists this reads.
    #
    # IT MERGES INTO THE STORED VIEWS RATHER THAN REPLACING THEM: one click is about one panel, and
    # the layout's other choices are none of its business.
    def update_view
      key, view = view_pair
      @project.update!(panels: stored.merge("views" => stored_views.merge(key => view))) if key
      # A refused pair redirects to the page with no anchor: `key` is the only thing that could
      # name one, and echoing an unvalidated key into the url is what this branch exists to refuse.
      redirect_to key ? project_path(@project, anchor: key) : project_path(@project)
    end

    # `[nil, nil]` FOR ANYTHING THAT IS NOT ONE KNOWN KEY MAPPED TO ONE KNOWN VIEW. `params[:view]`
    # is ActionController::Parameters for the `view[<key>]=<value>` the buttons post; a bare
    # `?view=list` (the shape the retired page-wide toggle used to send) is a String and answers
    # nothing here, which is why the old url is inert rather than half-working.
    def view_pair
      raw = params[:view]
      return [ nil, nil ] unless raw.is_a?(ActionController::Parameters)

      key, view = raw.to_unsafe_h.first
      return [ nil, nil ] unless vocabulary.include?(key.to_s) && Maker::Project::VIEWS.include?(view.to_s)

      [ key.to_s, view.to_s ]
    end

    # A MOVE REWRITES THE FULL ORDER, HIDDEN PANELS INCLUDED, so a panel that is currently hidden
    # keeps its slot rather than collapsing to the end the moment it is shown again — which is also
    # why the chooser lists every key rather than only the visible ones.
    #
    # AN UNKNOWN PANEL OR AN EDGE MOVE IS A NO-OP, NEVER AN ERROR: the buttons are rendered from
    # the same list this reads, so the only way to reach either is a hand-made request, and a
    # redirect that changed nothing is the honest answer to one.
    def moved
      order = layout.order.dup
      from = order.index(params[:panel].to_s)
      # "up" and "down" are the only directions; anything else is a hand-made request and moves
      # nothing (found in review: any other value read as "down").
      step = { "up" => -1, "down" => 1 }[params[:move].to_s]
      to = from && step && from + step
      return nil unless from && to&.between?(0, order.size - 1)

      order[from], order[to] = order[to], order[from]
      # ONLY THE QUESTION THAT WAS ASKED. A move writes the ORDER; the hidden set and the chosen
      # views ride along only when the row already carries them. Copying the kind's preset into the
      # column would freeze it there — a maker who later changes the kind on the edit form would
      # keep the OLD kind's hidden panels (found in review: one reorder click on a laser project
      # did exactly that, and switching to electronics left BOM and Wiring hidden). #destroy's rule,
      # applied to moves. `views` joins that slice for the plainer reason that dropping it would
      # reset every panel's view on the first arrow click.
      { "order" => order }.merge(stored.slice("hidden", "views"))
    end

    # THE FORM SENDS THE COMPLETE PICTURE: `order` is every panel in the order they were shown, and
    # `visible` is the checked subset, so hidden is simply the difference. An unchecked checkbox
    # sends NOTHING, which is exactly why `order` is a list of hidden fields rather than something
    # derived from `visible` — without it, unchecking a box would delete the panel from the order
    # instead of hiding it.
    def chosen
      attrs = params.require(:panels).permit(order: [], visible: [])
      order = (known(attrs[:order]) + layout.order) & vocabulary
      { "order" => order, "hidden" => order - known(attrs[:visible]) }.merge(stored.slice("views"))
    end

    def known(list) = Array(list).map(&:to_s) & vocabulary

    def stored = @project.panels.is_a?(Hash) ? @project.panels : {}

    def stored_views = stored["views"].is_a?(Hash) ? stored["views"] : {}
  end
end
