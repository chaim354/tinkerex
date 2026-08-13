module Maker
  # WHICH SAVED ADDON STATE PRODUCED A LIBRARY NODE — the reverse of Maker::AddonFile, resolved for
  # a whole page of nodes at a fixed cost.
  #
  # A MISSING NODE IS AN ABSENT KEY, NEVER A RAISE AND NEVER A nil VALUE. The caller holds a LIST
  # and most entries will not be addon output; the same contract the FileLayer port's `stat_all`
  # states for the same reason (CLAUDE.md §14a). A raise would 404 a page over one ordinary file,
  # and an explicit nil value cannot be told apart by `key?` from a node that resolved to nothing.
  #
  # THE QUERY COUNT MUST BE CONSTANT IN N. FilesController#index has never had pagination and was
  # measured at 2000 nodes (§12), so a per-node lookup is an N+1 that no fixture-sized test notices —
  # `test/integration/web/page_query_budget_test.rb` asserts constancy (never a literal: the counts
  # differ per LIBRARY_BACKEND) for exactly that reason.
  #
  # THIS CLASS DOES NOT KNOW WHICH ADDON PAGE TO OPEN, and the split is the point. It answers with
  # the state, whose `addon_key` is a `states_key`; mapping that to a route needs
  # Maker::Addons::Registry, which is a network fetch behind a 5-minute cache. Doing it here would
  # make an addon-source outage into a slow Files page for a user who has never opened /tools, so
  # the mapping belongs in a separate method that takes the index as an argument and is only worth
  # reaching once `for` has found a hit. `test/services/maker/addon_origin_test.rb` asserts the
  # zero-fetch property with a counting double rather than leaving it to be read off the code.
  module AddonOrigin
    # `addon_key` is DERIVED, not stored beside the state — one value copied out of another is the
    # drift shape §14e records, and here the copy would be free to disagree with the row it came
    # from. Callers get the same reader either way.
    Origin = Data.define(:state) do
      def addon_key = state.addon_key
    end

    module_function

    # Returns { node_id => Origin }. Absent keys for nodes no addon produced.
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
    # `order(:position, :id)` note.
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
        [ node_id, Origin.new(state:) ] if state
      }.to_h
    end
  end
end
