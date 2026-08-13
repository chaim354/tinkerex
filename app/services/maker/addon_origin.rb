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
    # TWO QUERIES WHEN SOMETHING MATCHED, ONE WHEN NOTHING DID (the ordinary case for a library
    # with no addon output) — AND THE JOIN WAS MEASURED BEFORE IT WAS REJECTED. The obvious spelling
    # is one statement — `eager_load(:addon_state).where(node_id: ids, addon_state: {user_id:})` —
    # and it is the SLOWER one on the deployment most likely to run it. SQLite plans that join by
    # driving from `maker_addon_states` on `user_id` and probing the composite
    # [addon_state_id, node_id], i.e. one seek per (state × node_id): the cost then grows with the
    # user's SAVED-STATE COUNT, which no query-count test can see because it is all inside one
    # statement. Measured against a scratch table of 20,000 addon files and ~5,000 saved states,
    # resolving one 2000-node page for a user owning 25 of those states and then 500 of them:
    #
    #     one query   4.5 ms @ 25 states ->  22.5 ms @ 500 states   (grows with the state count)
    #     two queries 0.5 ms @ 25 states ->   0.5 ms @ 500 states   (flat)
    #
    # It also decides whether the index this feature added is reached AT ALL. SQLite only prefers
    # `index_maker_addon_files_on_node_id` for the join form once `ANALYZE` stats exist, and nothing
    # in this repo ever runs ANALYZE — neither `storage/development.sqlite3` nor
    # `storage/test.sqlite3` has a `sqlite_stat1` table, so the join form leaves the migration that
    # accompanied this class as dead weight. Split in two, each statement's plan is forced and
    # stats-independent: `SEARCH maker_addon_files USING INDEX index_maker_addon_files_on_node_id`,
    # then `SEARCH maker_addon_states USING INTEGER PRIMARY KEY`. A SQLite-only `INDEXED BY` hint
    # was the rejected alternative — this codebase is deliberately adapter-agnostic (§14e).
    #
    # THE POSTGRES HALF IS REASONED, NOT MEASURED — there is no local Postgres on this box (§13's
    # env gotchas), so the numbers above are SQLite's. What carries across is the shape: both
    # statements are single-table lookups, one on an indexed column and one on a primary key, which
    # is the plan no planner gets wrong. The join is the form whose plan depends on the optimiser.
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
      states = Maker::AddonState.where(id: claims.map(&:last).uniq, user_id: user.id).index_by(&:id)
      claims.filter_map { |node_id, state_id|
        state = states[state_id]
        [ node_id, Origin.new(state:) ] if state
      }.to_h
    end
  end
end
