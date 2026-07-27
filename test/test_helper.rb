ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Devise registers its `mappings` (used by Devise::Mailer to resolve a record's scope) while
# DRAWING the routes (`devise_for :users`). Routes load lazily, so in a parallel test worker a
# Devise mailer can fire (e.g. a confirmation email when a confirmable account is created)
# BEFORE that worker has drawn its routes → an intermittent "Could not find a valid mapping"
# from Devise::Mailers::Helpers#find_scope!. Force the routes (and thus the mappings) to be
# loaded up front so the mailer can always resolve its scope.
Rails.application.reload_routes_unless_loaded if Rails.application.respond_to?(:reload_routes_unless_loaded)
Rails.application.routes.url_helpers # touch to ensure routes are drawn

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

    # Each parallel worker gets its OWN database — `ls storage/` shows `test.sqlite3_0` …
    # `test.sqlite3_9`, one per worker, exactly as the comment above says Rails does. (This
    # comment used to claim the opposite, "each worker shares one DB", and it was cited as the
    # explanation for an intermittent `SQLite3::BusyException` that a shared file would explain
    # and per-worker files cannot — see docs/STATUS.md, "The intermittent".) The chunk dir below
    # is still needed, and for the reason it gives rather than that one: the MemoryChunkStore
    # writes real files to tmp/dev-chunks that SURVIVE a transaction rollback, so DB isolation
    # buys nothing there. A keyspace-enumerating operation (Sync::ChunkReaper) in one worker would
    # otherwise see objects another worker — or an earlier, rolled-back test reusing an
    # autoincrement user id — left behind. Give each worker its own chunk dir so the storage
    # keyspace is as isolated as the DB already is. (Single-process runs leave it unset
    # → base dir, which is fine.)
    parallelize_setup do |worker|
      ENV["CHUNK_STORE_WORKER"] = worker.to_s
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Pin the FileLayer backend for the duration of one test.
    #
    # A test whose FIXTURES are chunk-shaped (ManifestChunk rows, Storage::ChunkStore blobs) is a
    # chunk test, and must SAY so: FileLayer.current otherwise reads the ambient LIBRARY_BACKEND,
    # so the whole suite run under LIBRARY_BACKEND=share pointed those tests at the Share adapter,
    # which looked for the fixtures' bytes on a disk that has none. The failure was the honest
    # signal ("this test depends on the ambient backend"), not a bug in either adapter — and the
    # ci.yml `test-share-backend` leg exists to keep catching it.
    #
    # Call it in setup. The teardown below restores the prior value whether or not it was called,
    # so nothing leaks into the next test in the worker.
    def pin_file_layer_backend(name)
      # Capture the prior value ONCE. A second call in the same test would otherwise overwrite it
      # with the first pin's value, and teardown would "restore" that into the next test in this
      # worker — a leak that no test would report.
      @file_layer_backend_prior = ENV["LIBRARY_BACKEND"] unless @file_layer_backend_pinned
      @file_layer_backend_pinned = true
      ENV["LIBRARY_BACKEND"] = name
      FileLayer.reset!
    end

    teardown do
      if @file_layer_backend_pinned
        ENV["LIBRARY_BACKEND"] = @file_layer_backend_prior
        FileLayer.reset!
      end
    end

    # Add more helper methods to be used by all tests here...
  end
end

module ActionDispatch
  class IntegrationTest
    # Bootstrap a CONFIRMED account + its first device DIRECTLY (no HTTP), returning the same
    # JSON-shaped payload the removed POST /v1/auth/register endpoint did. Device enrollment
    # in production now goes through POST /v1/devices/login (email+password via Devise); these
    # sync/maker integration tests don't exercise the human-auth bootstrap, so they build the
    # user + device directly (CLAUDE.md: tests build users/devices directly). Keys are strings
    # to match the old `JSON.parse(response.body)` return.
    def bootstrap_account(email:, device_name: "device")
      user = User.find_by(email:) ||
             User.create!(email:, confirmed_at: Time.current, omniauth_signup: true)
      device = Device.register!(user:, name: device_name)
      {
        "user_id" => user.id, "device_id" => device.id,
        "device_token" => device.plaintext_token, "head_seq" => user.head_seq
      }
    end

    # Token-only convenience for the many helpers that returned just the device token.
    def bootstrap_token(email:, device_name: "device")
      bootstrap_account(email:, device_name:)["device_token"]
    end
  end
end
