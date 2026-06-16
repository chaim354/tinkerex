ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers. Parallel workers each need their
    # own database; with the SQLite default that's a free per-worker file, but when an
    # external Postgres is selected via DATABASE_URL (managed/SaaS validation) the
    # per-worker DB-name derivation stalls, so run single-process there. Set
    # PARALLEL_WORKERS=1 to force single-process anywhere.
    if ENV["DATABASE_URL"].to_s.start_with?("postgres")
      parallelize(workers: 1)
    else
      parallelize(workers: :number_of_processors)
    end

    # Each parallel worker shares one DB (transactional fixtures isolate rows), but the
    # MemoryChunkStore writes real files to tmp/dev-chunks that survive a transaction
    # rollback. A keyspace-enumerating operation (Sync::ChunkReaper) in one worker would
    # then see objects another worker (or an earlier, rolled-back test reusing an
    # autoincrement user id) left behind. Give each worker its own chunk dir so the
    # storage keyspace is as isolated as the DB rows. (Single-process runs leave it unset
    # → base dir, which is fine.)
    parallelize_setup do |worker|
      ENV["CHUNK_STORE_WORKER"] = worker.to_s
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
