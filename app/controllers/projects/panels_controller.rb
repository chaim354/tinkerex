module Projects
  # The project page's own panel layout: the inline view toggle, the editor's Save, reset (stage
  # 4, S4-7; story 6.5; folder panels 2026-09-08; the page editor 2026-09-09).
  #
  # IT WRITES ONLY KEYS FROM THE PROJECT'S OWN VOCABULARY, and that is structural rather than a
  # validation someone can loosen: a view pair is checked against this project's vocabulary and
  # against what THAT panel offers, and a document goes through Maker::LayoutDocument, which merges
  # into the CURRENT layout and so can only ever name keys the layout already holds. A crafted
  # request cannot put `../../etc/passwd` in the stored order and projects/show.html.erb's
  # `render "projects/#{key}"` can never be handed a partial name that does not exist.
  # Maker::ProjectKind.layout_for filters again on the way OUT, for the rows this door did not
  # write (the v1 API, a console, a later migration) — two filters, one at each end.
  #
  # ONE PATCH, TWO SHAPES. `view[<key>]=<view>` is the toggle in a panel's head and saves at once;
  # `layout=<draft JSON>` is the editor's Save and writes the whole arrangement in one update. The
  # chooser's `move` and `panels[order][]` shapes retired with the chooser itself (spec §2).
  class PanelsController < ApplicationController
    include LayoutScoped

    def update
      return update_view if params[:view].present?
      return replace if params[:layout].present?

      head :bad_request
    end

    # RESET MEANS REMOVE THE OVERRIDE, not "write the current preset into the column": the second
    # would freeze this release's defaults onto the row and stop the project following its own kind
    # — including after the maker changes that kind on the edit form. Views, widths, titles and
    # intros go with it, by the same argument: they are the arrangement, not a separate setting.
    def destroy
      @project.update!(panels: nil)
      redirect_to project_path(@project), notice: "Page layout reset to the #{kind_label} defaults."
    end

    private

    # THE EDITOR'S SAVE. The document is what the browser holds; LayoutDocument validates it against
    # the layout AS IT IS NOW, so a folder renamed on disk mid-edit (share/s3 mint a new dir id)
    # drops out with a note rather than refusing the whole save, and anything a browser of ours
    # would never send — an unknown fixed key, a view Files does not offer — refuses the write and
    # returns to the editor with the reasons. Nothing is written on a refusal.
    def replace
      doc = document
      result = doc.from_draft(parsed_layout)
      if result.ok?
        @project.update!(panels: doc.column(result.draft))
        redirect_to project_path(@project), notice: [ "Page layout saved.", *result.notes ].join(" ")
      else
        redirect_to edit_layout_project_path(@project), alert: "The layout was not saved: #{result.errors.join(' ')}"
      end
    end

    def parsed_layout
      JSON.parse(params[:layout].to_s)
    rescue JSON::ParserError
      nil
    end

    # ONE PANEL'S VIEW (2026-09-08, folder panels; spec decision 6). The pair is validated on BOTH
    # sides — the key against this project's vocabulary, the value against what that panel offers —
    # and an invalid pair writes NOTHING rather than raising. It MERGES into the stored views: one
    # click is about one panel, and the layout's other choices are none of its business.
    def update_view
      key, view = view_pair
      @project.update!(panels: stored.merge("views" => stored_views.merge(key => view))) if key
      # A refused pair redirects to the page with no anchor: `key` is the only thing that could
      # name one, and echoing an unvalidated key into the url is what this branch exists to refuse.
      redirect_to key ? project_path(@project, anchor: key) : project_path(@project)
    end

    def view_pair
      raw = params[:view]
      return [ nil, nil ] unless raw.is_a?(ActionController::Parameters)

      pairs = raw.to_unsafe_h
      # EXACTLY ONE PAIR (found in review: two pairs wrote the first and dropped the rest), and the
      # value against what THIS panel offers rather than the global vocabulary — see
      # Maker::ProjectKind.offered_views for why Files cannot store `browser`.
      return [ nil, nil ] unless pairs.size == 1

      key, view = pairs.first
      # `current_layout.order` IS THE VOCABULARY (total against the folders that exist now), so the
      # door and the document read one list rather than two that can disagree.
      return [ nil, nil ] unless current_layout.order.include?(key.to_s) && Maker::ProjectKind.offered_views(key).include?(view.to_s)

      [ key.to_s, view.to_s ]
    end

    def stored = @project.panels.is_a?(Hash) ? @project.panels : {}

    def stored_views = stored["views"].is_a?(Hash) ? stored["views"] : {}
  end
end
