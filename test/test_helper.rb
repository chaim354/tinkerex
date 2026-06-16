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
