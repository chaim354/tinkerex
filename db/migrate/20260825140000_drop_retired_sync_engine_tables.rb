# frozen_string_literal: true

# THE EIGHT TABLES THE SYNC ENGINE LEFT BEHIND, DROPPED.
#
# Arc D Part 2 (2026-08-25) retired embedded `chunk`: the gem is gone, `Sync::` is undefined in this
# process, and the maker app no longer serves the device sync API. These tables were the engine's
# and nothing here has read or written them since. They were left in place at the time because
# CLAUDE.md §14j forbids REWRITING `db/migrate/` — four already-run migrations mix host and engine
# DDL in one `change`, and inventing new timestamps for the engine halves makes every
# already-migrated database report them PENDING and then fail with "table already exists".
#
# THAT RULE IS ABOUT REWRITING HISTORY, NOT ABOUT ADDING TO IT. A new migration that DROPS the
# tables is the ordinary, safe operation: it runs forward on every existing database, needs no
# hand-edited `schema_migrations` rows, and leaves the original migrations exactly as they are.
#
# EMPTINESS WAS VERIFIED ON EVERY LIVE DEPLOYMENT BEFORE THIS WAS WRITTEN, not assumed from the
# fact that no code references them: all eight reported 0 rows on chunk_remote, share AND s3
# (2026-08-25). Dropping a populated table is unrecoverable, so "nothing reads it" is not the
# question — "nothing is in it" is.
#
# NOT DROPPED, AND EACH FOR A REASON WORTH KNOWING:
#   * `remote_manifest_chunks` — a DIFFERENT table with a confusingly similar name, and it is LIVE:
#     FileLayer::ChunkRemote and its ChangelogSync both read it. Only the ENGINE's `manifest_chunks`
#     goes here.
#   * `users.head_seq` — still read by `User#next_seq!` and returned by V1::DevicesController, so it
#     is not dead weight despite being engine-shaped. Checked, not assumed.
#   * `nodes` — the maker app's own catalog on every backend, and chunk_remote's local mirror.
class DropRetiredSyncEngineTables < ActiveRecord::Migration[8.1]
  TABLES = %w[
    changelog_entries
    pending_commits
    conflicts
    file_locks
    share_links
    manifest_chunks
    versions
    chunks
  ].freeze

  def up
    # Order is not load-bearing: every foreign key on these eight points at `users`, and none points
    # at another of the eight (checked against db/schema.rb, not assumed). `if_exists` so this is
    # idempotent against a database that somehow never had them.
    TABLES.each { |t| drop_table t, if_exists: true }
  end

  # IRREVERSIBLE ON PURPOSE, RATHER THAN CARRYING A COPY OF SOMEONE ELSE'S DDL. Writing a `down`
  # means restating all eight `create_table` blocks here — which is precisely the second, drifting
  # copy of the engine's schema that Arc D Part 2 removed along with db/engine_schema.rb and its
  # cross-repo guard. The schema lives in chaim354/tinkerex-sync now; a database that needs these
  # tables back is a sync server, and it builds them from its own migrations.
  def down
    raise ActiveRecord::IrreversibleMigration,
          "These are the retired sync engine's tables. Their DDL lives in chaim354/tinkerex-sync " \
          "and is deliberately not duplicated here (CLAUDE.md §14j). If you need them back, you " \
          "are standing up a sync server — run ITS migrations, not this app's."
  end
end
