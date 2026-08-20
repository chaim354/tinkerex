# Boot-time Postgres connection-pooler safety check (G2 managed-Postgres hardening).
#
# Probes the DB connection and refuses to boot if a STATEMENT-mode pooler is in front of
# Postgres — that mode silently breaks `User#next_seq!`'s transaction-spanning FOR UPDATE row
# lock and can corrupt the changelog with duplicate seqs (see lib/sync/postgres_pooler_check.rb
# and docs/SYNC_SERVER.md "Connection pooler"). Best-effort, so it can be disabled with
# DB_SKIP_POOLER_CHECK=1. No-op on SQLite, when no Postgres primary is configured, and — Stage
# 3a — when this deployment runs no sync engine at all (see the GATED comment below).
#
# STAGE 3b PHASE A CLOSE-OUT: PostgresPoolerCheck moved under Sync:: (lib/sync/
# postgres_pooler_check.rb). THE OLD `require "postgres_pooler_check"` LINE THAT USED TO SIT
# HERE IS GONE, NOT MERELY RE-STRINGED, AND THAT WAS A REAL BOOT FAILURE, NOT A STYLE CHOICE.
# Verified live: at the point THIS initializer file loads, `Object.autoload?(:Sync)` is `nil`
# and `Object.const_defined?(:Sync)` is `false` — Zeitwerk has not yet registered the `Sync`
# autoload (`config/initializers/*.rb` load before Zeitwerk's main-loader `setup` finalizes on
# this Rails version, confirmed by probing this exact line, not assumed from how initializer
# ordering usually reads). A bare `require "sync/postgres_pooler_check"` at the TOP of this
# file therefore loaded a file whose `module Sync::PostgresPoolerCheck` needs `Sync` already
# resolvable — compact-form module reopening looks up its outer scope the same way a bare
# constant reference does, and there was nothing for it to find yet — raising `NameError:
# uninitialized constant Sync` and taking the whole boot down. The bare top-level
# `module PostgresPoolerCheck` this replaced never had this problem: it named no outer
# namespace, so nothing needed resolving first.
#
# THE FIX IS TO LOAD IT THE SAME WAY EVERY OTHER `Sync::` REFERENCE IN THIS APP ALREADY DOES —
# by reference, not by an eager top-level `require`. Every actual use of
# `Sync::PostgresPoolerCheck` below is already inside `after_initialize`, which runs once
# `Rails.application.initialize!` has finished the whole initializer sequence — by then
# Zeitwerk's `Sync` autoload IS registered (confirmed: this is the exact state the very first,
# working diagnostic probe for this task ran against), so the first `Sync::PostgresPoolerCheck`
# reference below autoloads it lazily, structurally identical to how `Sync::Gc`,
# `Sync::Storage::ChunkStore` and every other engine reference in `app/` resolve — no explicit
# require anywhere. This does not weaken the "refuse to boot on a bad pool" property:
# `after_initialize` still runs before `initialize!` returns, so a raise here still aborts boot
# before Puma binds a port, matching `lib/library_backend_check.rb`'s own comment on the same
# point.
Rails.application.config.after_initialize do
  # The whole eligibility decision — adapter prefix, the DB_SKIP_POOLER_CHECK escape hatch, AND
  # (Stage 3a) whether this deployment has a changelog at all — is Sync::PostgresPoolerCheck.probe?, so
  # it can be asserted without a database. THE CALL MUST STAY INSIDE THIS `begin`. It reads
  # db_config.adapter, which is config-only (it opens no connection) but can still raise
  # NoDatabaseError/ConnectionNotEstablished — both rescued below, which is the only reason
  # folding the env check in is behaviour-preserving. Hoist it above the `begin` and those two
  # become uncaught boot failures on a box whose DB is not reachable yet, for an operator who had
  # explicitly opted out.
  #
  # GATED, because this guard protects User#next_seq!'s row lock and NOTHING ELSE — and a share
  # or s3 deployment has no changelog, never calls next_seq!, and had been refusing to boot
  # behind a statement-mode pooler for a rule that cannot apply to it. The gate lives inside
  # `probe?` itself, as its `engine_present:` kwarg (default `Sync.engine_present?`), rather than
  # as a second `next unless` on this line — one call, one eligibility decision, so the wiring
  # cannot silently drift from what is actually tested. Stage 3a introduces the seam; Stage 3b
  # replaces Sync.engine_present?'s body with "is the engine mounted?" once there is an engine
  # object to ask — no caller here needs to change when that happens.
  begin
    pool = ActiveRecord::Base.connection_pool
    next unless Sync::PostgresPoolerCheck.probe?(adapter: pool.db_config.adapter)
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
    next # DB not reachable yet (asset precompile, etc.) — the check is advisory.
  end

  ActiveRecord::Base.connection_pool.with_connection do |conn|
    result = Sync::PostgresPoolerCheck.probe(conn)
    if result.error
      # The probe itself failing (e.g. advisory-lock funcs disallowed) is suspicious for
      # statement mode, but don't hard-fail boot on an unexpected DB error — log loudly.
      Rails.logger.warn("[postgres-pooler-check] probe error (could not verify pool mode): " \
                        "#{result.error.class}: #{result.error.message}")
    elsif !result.ok
      raise Sync::PostgresPoolerCheck.failure_message(result)
    end
  end
end
