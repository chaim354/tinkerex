# Boot-time Postgres connection-pooler safety check (G2 managed-Postgres hardening).
#
# Probes the DB connection and refuses to boot if a STATEMENT-mode pooler is in front of
# Postgres — that mode silently breaks `User#next_seq!`'s transaction-spanning FOR UPDATE row
# lock and can corrupt the changelog with duplicate seqs (see lib/postgres_pooler_check.rb and
# docs/SYNC_SERVER.md "Connection pooler"). Best-effort, so it can be disabled with
# DB_SKIP_POOLER_CHECK=1. No-op on SQLite, when no Postgres primary is configured, and — Stage
# 3a — when this deployment runs no sync engine at all (see the GATED comment below).
require "postgres_pooler_check"

Rails.application.config.after_initialize do
  # The whole eligibility decision — adapter prefix, the DB_SKIP_POOLER_CHECK escape hatch, AND
  # (Stage 3a) whether this deployment has a changelog at all — is PostgresPoolerCheck.probe?, so
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
    next unless PostgresPoolerCheck.probe?(adapter: pool.db_config.adapter)
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
    next # DB not reachable yet (asset precompile, etc.) — the check is advisory.
  end

  ActiveRecord::Base.connection_pool.with_connection do |conn|
    result = PostgresPoolerCheck.probe(conn)
    if result.error
      # The probe itself failing (e.g. advisory-lock funcs disallowed) is suspicious for
      # statement mode, but don't hard-fail boot on an unexpected DB error — log loudly.
      Rails.logger.warn("[postgres-pooler-check] probe error (could not verify pool mode): " \
                        "#{result.error.class}: #{result.error.message}")
    elsif !result.ok
      raise PostgresPoolerCheck.failure_message(result)
    end
  end
end
