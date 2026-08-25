# frozen_string_literal: true

require "test_helper"

module FileLayer
  class ChunkRemote
    # ARC C TASK 5 -- LAZY PROVISIONING, AND THE CONCURRENCY PROOF §14e'S `next_seq!` DEADLOCK IS
    # THE RECORDED PRECEDENT FOR TAKING SERIOUSLY. Two simultaneous first-uses of one fresh user
    # must mint exactly one remote library, never two, and never leave the user with no usable
    # token because the second racer's admin call landed a 409 nobody handled.
    class ProvisioningTest < ActiveSupport::TestCase
      # Records every call; answers a fresh, distinguishable device_token each time unless told to
      # raise instead. Mirrors what Transport ACTUALLY does on a non-2xx response (raise a
      # FileLayer::* exception), never a returned error hash -- a fake that returned `{error:
      # "..."}` instead would let Provisioning's own rescue go completely untested.
      class FakeAdminTransport
        attr_reader :calls

        def initialize(&responder)
          @calls = []
          @responder = responder
        end

        def post(path, body = {})
          @calls << [ path, body ]
          @responder ? @responder.call(body) : { "user_id" => 1, "device_id" => 1,
                                                 "device_token" => "minted-#{@calls.size}" }
        end
      end

      def new_user(email: "prov-#{SecureRandom.hex(6)}@example.com", sync_device_token: nil)
        User.create!(email:, password: "correct horse battery staple",
                     confirmed_at: Time.current, sync_device_token:)
      end

      # --- the fast path: nothing to provision -------------------------------------------------

      test "a user who already has a token gets it back untouched, no admin call at all" do
        user = new_user(sync_device_token: "already-have-one")
        admin = FakeAdminTransport.new { flunk "must not call the admin endpoint at all" }

        token = Provisioning.new(admin_transport: admin).call(user)

        assert_equal "already-have-one", token
        assert_empty admin.calls
      end

      # --- provisioning itself -------------------------------------------------------------------

      test "a user with no token gets one minted and PERSISTED" do
        user = new_user
        admin = FakeAdminTransport.new { { "user_id" => 9, "device_id" => 9, "device_token" => "brand-new" } }

        token = Provisioning.new(admin_transport: admin).call(user)

        assert_equal "brand-new", token
        assert_equal [ [ "/v1/admin/libraries", { email: user.email } ] ], admin.calls
        assert_equal "brand-new", user.reload.sync_device_token,
                     "the token must be written to the DB, not merely returned"
      end

      test "the minted token round-trips through encryption -- the raw column is not the plaintext" do
        user = new_user
        admin = FakeAdminTransport.new { { "device_token" => "plaintext-marker-xyz" } }

        Provisioning.new(admin_transport: admin).call(user)

        raw = ActiveRecord::Base.connection.select_value(
          "SELECT sync_device_token FROM users WHERE id = #{user.id}"
        )
        assert_not_equal "plaintext-marker-xyz", raw
        assert_not_includes raw.to_s, "plaintext-marker-xyz",
                            "the encrypted column must not contain the plaintext token as a substring"
        assert_equal "plaintext-marker-xyz", user.reload.sync_device_token,
                     "but reading it back through the model must decrypt to the original value"
      end

      # --- the 409 decision, pinned directly ------------------------------------------------------

      test "email_taken (409) becomes FetchError, not NotFound -- retryable framing, not 'gone'" do
        user = new_user
        admin = FakeAdminTransport.new do
          raise FileLayer::UnsupportedOperation, "/v1/admin/libraries: email_taken"
        end

        err = assert_raises(FileLayer::FetchError) { Provisioning.new(admin_transport: admin).call(user) }
        assert_match(/#{Regexp.escape(user.email)}/, err.message)
        assert_match(/operator/i, err.message,
                     "the message must say this needs a human, not merely 'try again'")
        assert_nil user.reload.sync_device_token, "a refused provision must not half-apply a token"
      end

      test "the race-loser shape (422 RecordInvalid, a DIFFERENT message than email_taken) is " \
           "handled THE SAME WAY, deliberately not distinguished from the ordinary 409" do
        user = new_user
        admin = FakeAdminTransport.new do
          raise FileLayer::UnsupportedOperation,
                "/v1/admin/libraries: Validation failed: Email has already been taken"
        end

        assert_raises(FileLayer::FetchError) { Provisioning.new(admin_transport: admin).call(user) }
      end

      # --- transport-level failures pass through unchanged ----------------------------------------

      test "an unreachable sync server's FetchError propagates as-is" do
        user = new_user
        admin = FakeAdminTransport.new { raise FileLayer::FetchError, "sync server unreachable" }

        assert_raises(FileLayer::FetchError) { Provisioning.new(admin_transport: admin).call(user) }
        assert_nil user.reload.sync_device_token
      end

      # --- the admin credential itself --------------------------------------------------------

      test "an unconfigured SYNC_ADMIN_TOKEN is a named FetchError, not a bare KeyError" do
        user = new_user
        prior_url = ENV["CHUNK_REMOTE_URL"]
        prior_admin = ENV["SYNC_ADMIN_TOKEN"]
        ENV["CHUNK_REMOTE_URL"] = "http://sync.example"
        ENV.delete("SYNC_ADMIN_TOKEN")

        err = assert_raises(FileLayer::FetchError) { Provisioning.new.call(user) }
        assert_match(/SYNC_ADMIN_TOKEN/, err.message)
      ensure
        prior_url.nil? ? ENV.delete("CHUNK_REMOTE_URL") : ENV["CHUNK_REMOTE_URL"] = prior_url
        prior_admin.nil? ? ENV.delete("SYNC_ADMIN_TOKEN") : ENV["SYNC_ADMIN_TOKEN"] = prior_admin
      end

      # --- a malformed 2xx is a contract violation, not a routine condition ------------------------

      test "a 2xx response missing device_token raises loudly rather than persisting a blank token" do
        user = new_user
        admin = FakeAdminTransport.new { { "user_id" => 1, "device_id" => 1 } }

        assert_raises(KeyError) { Provisioning.new(admin_transport: admin).call(user) }
        assert_nil user.reload.sync_device_token
      end

      # ============================================================================================
      # THE CONCURRENCY PROOF. Non-transactional, matching tinkerex-sync's ConcurrentSeqTest
      # (CLAUDE.md's own precedent for `user.with_lock` under real load): transactional fixtures
      # share ONE connection across every thread in the test, which would make `with_lock`'s row
      # lock a no-op against itself and prove nothing about the real mechanism. Each thread here
      # gets its OWN connection, its OWN freshly-loaded `User` instance for the SAME row (mirroring
      # two separate Puma requests, never the same in-memory object shared across threads), and a
      # CountDownLatch forces them to race for real rather than happening to run one after another.
      # ============================================================================================
      class ConcurrentTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        # RECORDS CALLS, AND SLEEPS -- the sleep is not padding, it is what makes this test
        # DETERMINISTIC rather than a timing gamble. `Transport.new` and a plain attribute read are
        # both fast enough that two real threads might simply never interleave inside the narrow
        # window between "check sync_device_token" and "write it" during a short test run, even
        # with a bad implementation -- the same reason CLAUDE.md §14e warns that a passing
        # concurrency test is not by itself evidence a lock works. Sleeping WHILE HOLDING the lock
        # (the fake stands in for the network call `#call` makes from inside `user.with_lock`)
        # guarantees the second thread has ample time to attempt -- and, if the implementation is
        # correct, correctly BLOCK on -- the same lock while the first is still inside it.
        class SlowAdminTransport
          def initialize(delay: 0.2)
            @mutex = Mutex.new
            @count = 0
            @delay = delay
          end

          def calls
            @mutex.synchronize { @count }
          end

          def post(path, body = {})
            @mutex.synchronize { @count += 1 }
            sleep @delay
            { "device_token" => "minted-#{SecureRandom.hex(8)}" }
          end
        end

        def setup
          @user = User.create!(email: "prov-conc-#{SecureRandom.hex(6)}@example.com",
                               password: "correct horse battery staple", confirmed_at: Time.current)
        end

        def teardown
          User.delete(@user.id) if @user
        end

        test "two simultaneous first-uses of the same fresh user provision EXACTLY ONCE" do
          admin = SlowAdminTransport.new
          provisioning = Provisioning.new(admin_transport: admin)

          latch = Concurrent::CountDownLatch.new(2)
          results = Queue.new
          errors = Queue.new

          threads = 2.times.map do
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                latch.count_down
                latch.wait
                begin
                  own_copy = User.find(@user.id)
                  results << provisioning.call(own_copy)
                rescue StandardError => e
                  errors << e
                ensure
                  ActiveRecord::Base.connection_handler.clear_active_connections!
                end
              end
            end
          end
          threads.each(&:join)

          raise errors.pop until errors.empty?

          tokens = []
          tokens << results.pop until results.empty?

          assert_equal 2, tokens.size, "both threads must return SOMETHING"
          assert_equal 1, tokens.uniq.size,
                       "both threads got DIFFERENT tokens -- the loser did not see the winner's " \
                       "committed value and provisioned a second time"
          assert_equal 1, admin.calls,
                       "the admin endpoint was hit #{admin.calls} times for ONE fresh user -- " \
                       "the lock did not serialize the two racing first-uses"
          assert_equal tokens.first, @user.reload.sync_device_token,
                       "the persisted token must be the one both callers agreed on"
        end
      end
    end
  end
end
