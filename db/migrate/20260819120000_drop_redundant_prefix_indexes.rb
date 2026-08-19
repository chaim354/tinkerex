# Drops ten single-purpose indexes whose column list is a strict PREFIX of another, non-partial
# index on the same table. A btree seek on `(a)` is answerable by any index led by `a`, so the
# narrow one only costs: another btree to maintain on every insert/update/delete of the row, and
# another copy of the leading column on disk.
#
# ORIGIN, so it does not regrow. `t.references :user, foreign_key: true` AUTO-INDEXES `user_id`;
# every one of these tables then added a composite led by `user_id` on top, and nothing removed the
# automatic one. A FUTURE `t.references` THAT WILL BE FOLLOWED BY A COMPOSITE MUST PASS
# `index: false` — precedent is in the vendored Active Storage migrations. The guard that catches it
# if you forget is in `test/architecture_invariants_test.rb` ("no index's column list is a strict
# prefix of another index's on the same table"); this comment is only here so the fix is obvious
# when that goes red.
#
# TWO INDEXES THAT LOOK IDENTICAL TO THE ABOVE ARE DELIBERATELY LEFT IN PLACE, and both are the
# same mechanism: SQLite APPENDS THE ROWID TO EVERY INDEX KEY, so a narrow `(a)` index can seek
# `a=? AND rowid <cmp> ?` and yield rows in id order, which a composite `(a, b)` cannot — it orders
# by `b` within the group and forces a sort.
#
#   * `index_maker_addon_states_on_user_id` — measured plan recorded at
#     `app/services/maker/addon_origin.rb:114-119`.
#
#   * `index_nodes_on_user_id` — `Sync::Tree.call` (`app/services/sync/tree.rb:12`) pages the
#     device INITIAL SYNC with `where(user_id:, deleted: false).where("id > ?", after).order(:id)
#     .limit(1000)`. With the index that is `SEARCH nodes USING INDEX index_nodes_on_user_id
#     (user_id=? AND rowid>?)` — one seek, LIMIT terminates it early. Without it the planner falls
#     to `index_nodes_on_user_id_and_updated_seq (user_id=?)` plus `USE TEMP B-TREE FOR ORDER BY`,
#     i.e. it reads the user's ENTIRE node set and sorts it to return 1000 rows — so a full export
#     goes from O(N) to O(N^2/limit). Measured on a 200,000-node table, twenty pages, warm cache:
#     0.01 s with the index against 0.30 s without (1.56 s cold). It costs 249,856 bytes on the
#     real dev database, 0.21% of it — so dropping it would buy a twentieth of what the ten buy and
#     cost thirty times the initial sync. `#find_each`/`#in_batches` page by id the same way, which
#     is why `Maker::Previews::MissingBackfill` (`missing_backfill.rb:74`) rides on it too.
#
# WHAT THE TEN ACTUALLY BUY, so the trade is legible. **Disk, measured** via `dbstat` on the real
# 116,318,208-byte dev database: 5,169,152 bytes, 4.44%, of which `manifest_chunks` is 3,149,824 and
# `chunks` 1,486,848 — 90% of the saving sits on the two hottest write paths in the app
# (`Sync::Commit#finalize`'s per-chunk `ManifestChunk.insert_all`, and `Sync::Gc.touch_refcounts!`'s
# `update_all`, which on Postgres can never be a HOT update because `refcount` is itself indexed).
# **Write time, measured** on SQLite, 250,000 `manifest_chunks` rows, min of 7 interleaved runs:
# 280 ms with the index against 250 ms without, ~11%. State that as DIRECTIONAL, not precise — the
# individual samples overlap (378/280/382/458/344/373/332 against 250/369/392/563/367/341/434), so
# the minimum is the only estimator this box supports. The structural claim is the durable one:
# one fewer btree to descend and split per row inserted.
#
# THE READ SIDE, probed both ways on the real dev database. Every query is still index-served and no
# SCAN appears anywhere, but THREE plans acquire a `USE TEMP B-TREE FOR ORDER BY` and none of them
# is a regression that matters — the reasoning is per table, not a blanket wave:
#
#   * `chunks` — `Sync::Gc.sweep_orphans!`'s `find_each` (`gc.rb:152`). AN EARLIER VERSION OF THIS
#     COMMENT SAID THIS PLAN "GETS BETTER" AND THAT IS WRONG IN DETAIL — a reviewer re-measured
#     per batch. Batch 1 ALREADY planned `(user_id, refcount)` + temp b-tree before the drop, so
#     nothing was acquired and nothing improved. What changes is batch 2+, which LOSES the very
#     appended-rowid seek `nodes` is exempted for below. The outcome is still fine, and the
#     asymmetry is the part worth writing down: here the seek is lost over a set the composite
#     has already FILTERED to `refcount <= 0` — empty in steady state, so the sort sorts nothing
#     (probed: user 418, 503 chunks, 0 orphans) — whereas `nodes` would lose it over the user's
#     ENTIRE library. Same mechanism, opposite verdicts, decided by what the predicate leaves.
#   * `pending_commits` — the `find_each` in `Sync::ChunkReaper.pending_hashes` and
#     `Sync::PendingCommitReaper`. The table holds only IN-FLIGHT commits (30 rows across the whole
#     dev database), so sorting one user's handful is free.
#   * `versions` — reachable only from an unqualified `user.versions ... ORDER BY id`, and NO SUCH
#     CALLER EXISTS: every site carries `version_id` or `node_id`, and `apply_retention!`'s
#     `user.versions.distinct.pluck(:node_id)` (`gc.rb:88`) was already served by the covering
#     `(user_id, node_id, id)` composite BEFORE this change, not by the index being dropped.
#
# `Sync::Gc.touch_refcounts!` is untouched in plan: all four call sites pass
# `user.chunks.where(chunk_hash: hashes)`, which uses `index_chunks_on_user_id_and_chunk_hash`
# before and after. `dependent: :destroy`'s cascade stays index-served on
# every one of the ten. Precisely: `:destroy` issues `SELECT ... WHERE user_id = ?` and deletes per
# row by id — it is `:delete_all` that emits the single `DELETE ... WHERE user_id = ?` this line
# used to name. Both forms were probed; the conclusion is identical for both, on every one of the
# ten (a foreign key needs no index of its own on either adapter).
#
# NO `algorithm: :concurrently`: SQLite rejects it, and using it would split this migration by
# adapter, which CLAUDE.md §14e forbids. On Postgres each DROP INDEX takes a brief ACCESS EXCLUSIVE
# lock (metadata plus an unlink), which is acceptable for ten of them.
#
# EACH `remove_index` PASSES ITS COLUMNS, NOT JUST ITS NAME. `ActiveRecord`'s command recorder
# (`command_recorder.rb`) raises `IrreversibleMigration` for a `remove_index` given only `name:`,
# because it has nothing to rebuild the index from. Name-only would migrate fine and fail on
# `db:rollback` — verified by running it.
class DropRedundantPrefixIndexes < ActiveRecord::Migration[8.1]
  def change
    # (user_id) < (user_id, seq) unique
    remove_index :changelog_entries, :user_id, name: "index_changelog_entries_on_user_id"

    # (user_id) < (user_id, chunk_hash) unique, and < (user_id, refcount)
    remove_index :chunks, :user_id, name: "index_chunks_on_user_id"

    # (user_id, node_id) < (user_id, node_id, incoming_version_id) unique
    remove_index :conflicts, %i[user_id node_id], name: "index_conflicts_on_user_id_and_node_id"

    # (addon_state_id) < (addon_state_id, node_id) unique
    remove_index :maker_addon_files, :addon_state_id,
                 name: "index_maker_addon_files_on_addon_state_id"

    # (addon_state_id) < (addon_state_id, revision) unique
    remove_index :maker_addon_state_revisions, :addon_state_id,
                 name: "index_maker_addon_state_revisions_on_addon_state_id"

    # (user_id, attachable_type, attachable_id) < (..., node_id) unique
    remove_index :maker_file_attachments, %i[user_id attachable_type attachable_id],
                 name: "index_maker_file_attachments_on_attachable"

    # (user_id) < (user_id, manifest_id, seq) unique
    remove_index :manifest_chunks, :user_id, name: "index_manifest_chunks_on_user_id"

    # (user_id) < (user_id, commit_id) unique
    remove_index :pending_commits, :user_id, name: "index_pending_commits_on_user_id"

    # (user_id) < (user_id, version_id)
    remove_index :share_links, :user_id, name: "index_share_links_on_user_id"

    # (user_id) < (user_id, version_id) unique, and < (user_id, node_id, id)
    remove_index :versions, :user_id, name: "index_versions_on_user_id"
  end
end
