module Maker
  # WHICH SAVED ADDON STATE PRODUCED A LIBRARY NODE — the reverse of Maker::AddonFile, resolved for
  # a whole page of nodes at a fixed cost.
  #
  # A MISSING NODE IS AN ABSENT KEY, NEVER A RAISE AND NEVER A nil VALUE. The caller holds a LIST
  # and most entries will not be addon output; the same contract the FileLayer port's `stat_all`
  # states for the same reason (CLAUDE.md §14a). A raise would 404 a page over one ordinary file,
  # and an explicit nil value cannot be told apart by `key?` from a node that resolved to nothing.
  #
  # THE QUERY COUNT MUST BE CONSTANT IN N. FilesController#index has never had pagination in flat
  # mode and was measured at 2000 nodes (§12), so a per-node lookup is an N+1 that no fixture-sized
  # test notices — `test/integration/web/page_query_budget_test.rb` asserts constancy for exactly
  # that reason. CONSTANCY RATHER THAN A LITERAL because GROWTH is the defect and a literal would
  # also go red on any unrelated query that page gains; NOT because the number varies by backend,
  # which an earlier draft of this comment claimed. This method never touches the port at all —
  # probed at **2 queries on each of chunk, share and s3**, with three different adapters genuinely
  # resolved — so its cost is the same on every leg.
  #
  # THIS CLASS DOES NOT KNOW WHICH ADDON PAGE TO OPEN, and the split is the point. It answers with
  # the state, whose `addon_key` is a `states_key`; mapping that to a route needs
  # Maker::Addons::Registry, which is a network fetch behind a 5-minute cache. Doing it here would
  # make an addon-source outage into a slow Files page for a user who has never opened /tools, so
  # the mapping belongs in a separate method that takes the index as an argument and is only worth
  # reaching once `for` has found a hit. `test/services/maker/addon_origin_test.rb` asserts the
  # zero-fetch property with a counting double rather than leaving it to be read off the code.
  module AddonOrigin
    module_function

    # Returns { node_id => Maker::AddonState }. Absent keys for nodes no addon produced.
    #
    # THE STATE ITSELF, NOT A WRAPPER, AND THE WRAPPER WAS REMOVED RATHER THAN NEVER WRITTEN. This
    # shipped as `Origin = Data.define(:state)` with a derived `addon_key` reader, on the reasoning
    # that a caller would want both. The caller now exists — AddonOrigins#addon_origins_for — and it
    # reads the state and nothing else, passing it to `link_for` (which asks the row for its own
    # `addon_key`) and carrying it into the view for `name`/`revision`. A one-member Data whose only
    # extra reader nobody calls is ceremony between the caller and the row, so it is gone; adding one
    # back is a mechanical change on the day a second value genuinely needs to travel.
    #
    # TWO QUERIES WHEN SOMETHING MATCHED, ONE WHEN NOTHING DID (the ordinary case for a library with
    # no addon output) — AND THE JOIN WAS MEASURED BEFORE IT WAS REJECTED. The obvious spelling is
    # `joins(...).where(node_id:, maker_addon_states: {user_id:})`, and it loses on cost while
    # winning nothing on statement count. SQLite plans it by driving from `maker_addon_states` on
    # `user_id` and probing the composite [addon_state_id, node_id], one seek per (state × node_id),
    # so the cost grows with the user's SAVED-STATE COUNT — which no query-count test can see,
    # because it is all inside one statement. Measured on 20,000 addon files / 5,000 saved states,
    # every state owning files, resolving one 2000-node page:
    #
    #                          user owns 25 states     user owns 500 states
    #     join      40 hits            3.6 ms                  64.7 ms      (grows)
    #     join      ALL MISS           3.5 ms                  64.6 ms      (grows)
    #     this code 40 hits            0.5 ms                   0.5 ms      (flat)
    #     this code ALL MISS           0.5 ms                   0.4 ms      (flat)
    #
    # THE ALL-MISS ROW IS THE ONE THAT SETTLES IT: 65 ms to return ZERO rows, on the ordinary
    # library that has never saved anything from an addon. That is the common case, not the corner.
    #
    # AND THE JOIN IS NOT EVEN ONE STATEMENT. `joins(<string>) + includes(:addon_state)` — the exact
    # spelling proposed for this method — emits the join AND a separate
    # `maker_addon_states WHERE id IN (…)` preload whenever it matches a row: 2 statements, the same
    # count as below (probed; it collapses to 1 only when the result is empty and there is nothing
    # to preload). So there was never a statement to save.
    #
    # THE JOIN'S PLAN IS OPTIMISER-DEPENDENT; THIS ONE IS NOT — that, and not any fact about
    # ANALYZE, is the durable half of the argument. Probed, the join plans three different ways:
    # production-scale with no stats it probes the composite; production-scale after ANALYZE it
    # switches to `index_maker_addon_files_on_node_id`; at FIXTURE scale after ANALYZE it plans a
    # bare `SCAN maker_addon_files`. (An earlier draft of this comment said the node_id index is
    # only preferred once ANALYZE stats exist. True at production scale, false at fixture scale, and
    # misleading either way — it invites "then just run ANALYZE", which would indeed repair the
    # join's plan on a big table while leaving the cost above unexplained.) Split in two, both plans
    # are fixed at every scale and stats configuration, which is what
    # `addon_origin_test.rb`'s plan assertion pins. A SQLite-only `INDEXED BY` hint was the rejected
    # alternative — this codebase is deliberately adapter-agnostic (§14e).
    #
    # THE POSTGRES HALF IS REASONED, NOT MEASURED — there is no local Postgres on this box (§13's
    # env gotchas), so every number above is SQLite's. What carries across is the shape: both
    # statements are single-table lookups on an indexed column, which is the plan no optimiser has
    # to guess at. The join is the form whose plan depends on one.
    #
    # NOT TEST-PINNED, and said here rather than quietly left unguarded: the defect is a query PLAN,
    # not a query COUNT, so both spellings are constant in N and both pass every assertion in
    # addon_origin_test.rb. The numbers above are the guard. Same shape as Maker::AddonState's
    # note on its `:id` tiebreak.
    def for(user:, node_ids:)
      ids = Array(node_ids).compact.uniq
      # NOT A GUARD, AND THE TEST BESIDE IT CANNOT FAIL — said rather than left to be discovered.
      # `where(node_id: [])` compiles to `WHERE 1=0` and Rails short-circuits `pluck` on it without
      # issuing a statement (probed: 0 SQL events), so the zero-query property holds with or without
      # this line. It stays because that is a framework optimisation and this is the contract, and
      # because `Array(nil)` lands here too — but a reader must not mistake it for the thing that
      # makes the property true.
      return {} if ids.empty?

      # ORDERED SO THE ANSWER IS STABLE, because TWO STATES CAN CLAIM ONE NODE: a save that answers
      # the 409 with `overwrite: "1"` rewrites a node another state produced, and
      # Maker::Addons::LibraryOutput leaves the older state's row in place on purpose. `to_h` below
      # keeps the LAST entry, so the most recently created claim wins.
      #
      # A DETERMINISTIC CHOICE AMONG CLAIMANTS, NOT A CLAIM ABOUT WHO WROTE THE BYTES LAST —
      # nothing on the row records that (`upsert_file!` does not touch `updated_at` when the
      # attributes are unchanged). Not test-pinned either, for AddonState's reason: SQLite returns
      # these rows in rowid order with or without the clause, so an assertion on the winner passes
      # identically once it is removed — a guard that cannot fail. It is correctness against a
      # planner that is free to reorder.
      claims = Maker::AddonFile.where(node_id: ids).order(:id).pluck(:node_id, :addon_state_id)
      return {} if claims.empty?

      # THE TENANT SCOPE, AND IT IS THE WHOLE GUARD. The lookup above is deliberately unscoped so
      # its plan stays forced, so nothing else stops another user's row from being read here — only
      # this `user_id` stops one being ANSWERED. Unlike Tools::AddonsController#file there is no
      # adapter re-scoping underneath to catch a mistake, so a test that passes without this line
      # would be proving nothing; `addon_origin_test.rb` mutation-checks it.
      #
      # ITS PLAN CHANGES SHAPE WITH THE IN-LIST AND BOTH SHAPES ARE FINE — worth writing down,
      # because a transcript taken from a 3-row fixture does not look like production's. Probed at
      # 5,000 states: up to 3 ids it is `SEARCH maker_addon_states USING INTEGER PRIMARY KEY
      # (rowid=?)`; from 4 ids up it is `SEARCH maker_addon_states USING INDEX
      # index_maker_addon_states_on_user_id (user_id=? AND rowid=?)`. Both are one seek per id.
      states = Maker::AddonState.where(id: claims.map(&:last).uniq, user_id: user.id).index_by(&:id)
      claims.filter_map { |node_id, state_id|
        state = states[state_id]
        [ node_id, state ] if state
      }.to_h
    end

    # THE ADDON PAGE THAT OPENS THIS STATE, as {url:, title:}, or nil.
    #
    # `addons` IS `Registry.all`, PASSED IN RATHER THAN FETCHED HERE, and that argument is the whole
    # reason this is a second method instead of a field on `for`'s answer. Registry.all is a manifest
    # fetch behind a 5-minute cache; taking the index as an argument means a caller resolving a page
    # of nodes fetches it ONCE, and — the half that matters — a library with no addon output never
    # reaches this method at all, so an addon-source outage cannot slow down a Files page belonging
    # to someone who has never opened /tools. AddonOrigins#addon_origins_for is the caller that holds
    # up that order, and test/integration/web/addon_origin_surfaces_test.rb drives it through a real
    # request with a counting double.
    #
    # BOTH VALUES COME BACK TOGETHER because the caller needs both and this is the one place that
    # knows WHICH addon was chosen. Returning the URL alone and re-deriving the title by parsing the
    # key back out of it is one value derived from another — the drift shape §14e records.
    #
    # PREFER AN EXACT `key` MATCH, THEN FALL BACK TO `states_key`. Registry defaults states_key to
    # key, so the exact match is the ordinary case; the fallback exists for the one thing states_key
    # is for — a successor addon ("boxes-next") that took over a predecessor's saved-state namespace
    # by mutual declaration — so output saved under the old key still opens in the addon that now
    # owns it.
    #
    # TWO CASES ARE IMPERFECT, NOT ONE, AND NEITHER IS A WRONG WRITE. (a) Where two addons share a
    # states_key the choice is a deterministic GUESS rather than a fact, and the sibling's page may
    # open — a wrong PAGE. (b) Where ONE addon's `key` matches a state's `addon_key` while its OWN
    # `states_key` has diverged, the `key` arm wins and opens the RIGHT page UN-PREFILLED: a state's
    # `addon_key` is always some addon's states_key (that is the scope it was written through), so a
    # row predating the divergence still carries the bare key, and Tools::AddonsController then
    # re-resolves `?state=` through `for_addon(states_key)` — a scope that no longer contains it —
    # and serves `launch.stateId: nil`. The addon opens as a fresh session instead of on that design.
    #
    # (b) IS COMMENT COVERAGE, NOT A LIVE DEFECT: nothing this deployment serves declares a diverging
    # states_key (the suite's only such manifest is a synthetic "widgetkit-next"), and the case needs
    # a divergence introduced AFTER states were saved. It is recorded rather than fixed because the
    # preference order is right for the ordinary case and every alternative trades a wrong page for a
    # wrong one somewhere else.
    #
    # WHAT MAKES BOTH SAFE is that nothing downstream trusts this choice — that same re-resolution
    # through `for_addon(states_key)` is the authority, so a page that does not in fact own the state
    # simply renders as a fresh session rather than acting on somebody else's row.
    #
    # nil IS A REAL ANSWER AND THE CALLER MUST DROP THE NODE, not fall back to a guessed path. No
    # registered addon claims the key when a manifest has been withdrawn, when this deployment's
    # addon source is down (Registry.manifests answers [] for that request), or when the state was
    # written by an addon this deployment does not serve. A link to /tools/<key> in any of those
    # cases is a 404 dressed as a feature; no link at all is the honest surface.
    def link_for(state, addons:)
      addon = addons.find { |a| a.key == state.addon_key } ||
              addons.find { |a| a.states_key == state.addon_key }
      return nil if addon.nil?

      { url: Rails.application.routes.url_helpers.tools_addon_path(addon.key, state: state.id),
        title: addon.title }
    end
  end
end
