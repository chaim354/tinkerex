# THE TOMBSTONE HALF OF `nodes (user_id, storage_path)` (F-S05-1, 2026-10-19 simplification audit).
# Library::Reconciler asks for a tombstone BY PATH before it creates anything — #create_or_revive! for
# every file a pass brings in, #ensure_dirs for every directory it writes — and the only index carrying
# `storage_path` was the live-row one, partial on `deleted = false`, which a `deleted = true` query
# cannot use. So each lookup read every row the user owns, and a first scan or a large import of N
# files cost ~N^2/2 row visits: negligible on the ~5k-row libraries deployed today, projected at ~10
# minutes for 100k files and past ScanJob's 1-hour per-user semaphore near 240k. An S3 first scan
# hashes nothing, so that create path IS its whole cost.
#
# PARTIAL ON THE COMPLEMENT: the two indexes hold every row that has a path exactly once between them,
# and the live-row one keeps every plan it had. NOT UNIQUE, because tombstones can share a path — a
# file moved onto a tombstoned path and then deleted, a path whose kind changed and changed back —
# which is why both lookups take the newest. A trash tombstone's `storage_path` is NULL, so it sits
# here under NULL and still cannot match a path lookup: §14a's two tombstone kinds stay apart exactly
# as before.
#
# `deleted = true` mirrors the live-row index's `deleted = false`. Either is usable only by a query
# that binds `deleted` to the matching value, which is why #ensure_dirs' lookup gained that term in the
# same change. On Postgres a partial index is chosen only under a plan that sees the bound value; every
# scannable deployment is SQLite today, and test/services/library/reconciler_test.rb asserts the plan.
class IndexNodeTombstonesByPath < ActiveRecord::Migration[8.1]
  def change
    add_index :nodes, [ :user_id, :storage_path ], where: "deleted = true",
              name: "index_nodes_on_user_id_and_storage_path_tombstones"
  end
end
