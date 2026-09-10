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
  #
  # SAVE WRITES CONTENT NOW, NOT ONLY AN ARRANGEMENT (2026-09-09, content blocks; spec §5, §6):
  # `maker_project_blocks` rows, the project's description and its cover ride the same document, in
  # ONE transaction, so a link with a bad URL anywhere in the draft leaves every row as it was.
  # Reset (#destroy) still touches only the override: blocks, the description and the cover are
  # content, not arrangement, and a reset of the defaults must not delete a maker's writing.
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
      posted = parsed_layout
      result = doc.from_draft(posted)
      return refuse(result.errors) unless result.ok?

      held = held_by_browser(result.draft, posted)
      begin
        @project.transaction do
          keys = write_blocks(doc.blocks_from(held)).merge(mint_tab_keys(held))
          attrs = { panels: doc.column(held).transform_values { |value| rekey(value, keys) } }
          if (page = doc.page_from(held))
            attrs[:description] = page["description"]
            attrs[:cover_node_id] = page["cover_node_id"]
          end
          @project.update!(attrs)
        end
      rescue ActiveRecord::RecordInvalid => e
        return refuse([ e.record.errors.full_messages.join(", ") ])
      end
      redirect_to project_path(@project), notice: [ "Page layout saved.", *result.notes ].join(" ")
    end

    def refuse(errors)
      redirect_to edit_layout_project_path(@project), alert: "The layout was not saved: #{errors.join(' ')}"
    end

    # THE BROWSER'S DRAFT IS THE WHOLE TRUTH OF BLOCKS; A PASTED LAYOUT IS NOT (spec §5), AND THE
    # TWO RULES MEET HERE. Maker::LayoutDocument#merge deliberately KEEPS an entry the document
    # does not name — that is what lets a layout shared from a smaller project leave this project's
    # own panels alone, and what makes "a block is never deleted by its absence from pasted YAML"
    # true. But the editor posts EVERY slot it holds, so a block whose slot was deleted is absent
    # on purpose, and Save has to be able to see the difference. The POSTED document says which
    # blocks the browser still holds; every other entry (a panel, a folder) is untouched, because
    # only a block's absence carries that meaning.
    #
    # ONE FILTERED DRAFT FEEDS ALL THREE OUTPUTS — the rows, the column and the page — so the order
    # cannot name a block the rows no longer hold.
    def held_by_browser(draft, posted)
      held = Array(posted["panels"]).filter_map { |e| e["key"].to_s if e.is_a?(Hash) && e["kind"].present? }.to_set
      draft.merge("panels" => draft["panels"].reject { |e| e["kind"] && !held.include?(e["key"]) })
    end

    # ROWS FOR NEW KEYS CREATED, ROWS FOR EXISTING KEYS UPDATED, ROWS THE DRAFT NO LONGER LISTS
    # DESTROYED — inside the caller's transaction, so ONE bad block writes nothing at all (spec §5).
    # Returns { "block:new-1" => "block:<minted key>" } so the column's own keys can be rewritten to
    # the rows that now exist: the browser's placeholder names nothing outside its own session.
    #
    # `blocks` IS THE PRE-WRITE READ (LayoutScoped memoises it, and `document` above already forced
    # it), which is what makes `existing` the set as it was rather than the set as this method is
    # leaving it.
    def write_blocks(drafted)
      existing = blocks.index_by(&:layout_key)
      keys = {}
      drafted.each do |b|
        attrs = b.except("key")
        if existing.key?(b["key"])
          existing.delete(b["key"]).update!(attrs)
        else
          keys[b["key"]] = @project.blocks.create!(attrs.merge("user" => current_user)).layout_key
        end
      end
      existing.each_value(&:destroy!)
      # BELT AND BRACES BEHIND THE DOCUMENT'S OWN CAP CHECK, and it raises the way every other
      # refusal in this transaction does so one rescue answers for all of them.
      if @project.blocks.count > Maker::ProjectBlock::CAP
        over = @project.blocks.new(kind: "text")
        over.errors.add(:base, "That would leave more than #{Maker::ProjectBlock::CAP} blocks on the page.")
        raise ActiveRecord::RecordInvalid.new(over)
      end
      keys
    end

    # A NEW TAB HAS NO ROW TO MINT A KEY FOR, so the door mints it here (2026-09-09, tabs; spec §5):
    # `tab:new-N` becomes `tab:<12 hex>` in `order` and `titles` through the same rekey a block's
    # placeholder goes through. Nothing else to write — the key's presence in the order is the tab.
    def mint_tab_keys(draft)
      draft["panels"].filter_map do |e|
        [ e["key"], Maker::ProjectKind.tab_key(Maker::ProjectKind.new_tab_key) ] if e["kind"] == "tab" && e["key"].to_s.match?(Maker::ProjectKind::NEW_TAB_KEY)
      end.to_h
    end

    # A `new-` KEY IN THE COLUMN BECOMES THE ROW'S OWN — or, for a tab, the key this door just
    # minted. Arrays are `order` and `hidden`, hashes are `widths` (blocks carry one, a tab never
    # does) and the three sparse text maps — of which `titles` DOES carry a `new-` key now: a tab's
    # NAME is a title, so a rekey that skipped the hashes would strand a new tab's name under a key
    # nothing else names (Maker::LayoutDocument#column says which map holds what).
    def rekey(value, keys)
      case value
      when Array then value.map { |k| keys.fetch(k, k) }
      when Hash then value.to_h { |k, v| [ keys.fetch(k, k), v ] }
      else value
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
