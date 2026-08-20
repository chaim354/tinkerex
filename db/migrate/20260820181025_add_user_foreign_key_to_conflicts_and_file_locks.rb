class AddUserForeignKeyToConflictsAndFileLocks < ActiveRecord::Migration[8.1]
  # `conflicts` and `file_locks` were created (20260612020000, 20260612030000) with
  # `t.integer :user_id, null: false` where every sibling engine table -- `changelog_entries`,
  # `chunks`, `devices`, `nodes`, `pending_commits`, `share_links`, `versions`,
  # `manifest_chunks`, `maker_addon_states` -- uses `t.references :user, foreign_key: true`.
  # Nothing recorded why these two were left out, and re-reading both migrations and the app
  # code that writes them (Sync::Commit, Sync::Conflicts, Sync::Locks -- always through
  # `user.conflicts`/`user.file_locks`, so `user_id` is never anything but a real user's id on
  # any path this app has) turned up no reason: it reads as an oversight, not a decision.
  #
  # An unenforced ownership edge is exactly what gets violated once the database is no longer
  # shared -- Stage 3b's whole premise (docs/superpowers/plans/2026-08-20-stage-3a-decouple-the-
  # engine.md, Task 7). Adding the constraint now, while it is still cheap, is better than
  # discovering a cross-tenant row after the split makes it someone else's problem to notice.
  #
  # NO `change_column` NEEDED: both columns are already declared `t.integer :user_id`, and under
  # this app's SQLite dumps that is the exact same rendered type every `t.references :user,
  # foreign_key: true` sibling produces (compare db/schema.rb's "conflicts"/"file_locks" blocks
  # against "devices"/"nodes" -- all `t.integer "user_id"`, never `t.bigint`). Only the missing
  # constraint itself needs adding.
  #
  # SQLITE CAVEAT (CLAUDE.md §4/§7 -- SQLite in dev/test, Postgres in production): SQLite has no
  # `ALTER TABLE ... ADD CONSTRAINT`, so `add_foreign_key` on this adapter rebuilds each table
  # (copy-rename), which is why this migration touches nothing else about either table -- a
  # rebuild is the right primitive for this and Rails already owns it. Verified against this
  # app's SQLite dev database (`bin/rails db:migrate`) and against a real cross-tenant write
  # attempt afterward (see the mutation check recorded in the Task 7 report). NOT verified
  # against Postgres in this environment -- there is no local Postgres here (CLAUDE.md's own
  # "Env gotchas" line says so) -- but `add_foreign_key :table, :other_table` on an existing,
  # already-populated, already-integer column is ordinary, well-trodden Postgres DDL with no
  # adapter-specific hazard the way the SQLite rebuild has; unlike SQLite it takes a lock rather
  # than rewriting the table, which matters only at a scale this app is nowhere near yet.
  def change
    add_foreign_key :conflicts, :users
    add_foreign_key :file_locks, :users
  end
end
