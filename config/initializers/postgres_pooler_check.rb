# Boot-time Postgres connection-pooler safety check (G2 managed-Postgres hardening).
#
# Probes the DB connection and refuses to boot if a STATEMENT-mode pooler is in front of
# Postgres — that mode silently breaks `User#next_seq!`'s transaction-spanning FOR UPDATE row
# lock and can corrupt the changelog with duplicate seqs (see lib/postgres_pooler_check.rb and
# docs/SYNC_SERVER.md "Connection pooler"). Best-effort, so it can be disabled with
# DB_SKIP_POOLER_CHECK=1. No-op on SQLite and when no Postgres primary is configured.
require "postgres_pooler_check"

Rails.application.config.after_initialize do
  next if ENV["DB_SKIP_POOLER_CHECK"] == "1"

  begin
    pool = ActiveRecord::Base.connection_pool
    next unless pool.db_config.adapter.to_s.start_with?("postgres")
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
