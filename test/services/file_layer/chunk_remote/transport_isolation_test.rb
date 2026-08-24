# frozen_string_literal: true

require "test_helper"

module FileLayer
  class ChunkRemote
    # ARC C TASK 4 -- THE TEST THAT IS THE WHOLE POINT OF THE TASK. `FileLayer.current` is ONE
    # adapter instance shared by every Puma thread; before this arc `#transport` memoized the
    # result of its first call onto `self` (`@transport ||= Transport.new(token: ENV.fetch(
    # "CHUNK_REMOTE_TOKEN"))`), so the first user's request decided the token every OTHER user's
    # request got until the process restarted. This suite drives ONE shared adapter instance --
    # never one per user, which would prove nothing about the shared-instance defect -- and asserts
    # every observed token, sequential and concurrent, belongs to the user that request was for.
    #
    # `.send(:transport, user)` AND `instance_variable_get(:@token)`: `#transport` is private (the
    # port never exposes it, and this suite has no reason to change that), and `Transport` has no
    # public reader for the credential it holds -- correctly, nothing in production needs one. Both
    # are read here anyway, matching this repo's own precedent for reaching past encapsulation
    # specifically to make a fact assertable in a test (build_chunk_remote_test.rb reads
    # `FileLayer`'s own `@current` the same way).
    class TransportIsolationTest < ActiveSupport::TestCase
      setup do
        @prior_url = ENV["CHUNK_REMOTE_URL"]
        ENV["CHUNK_REMOTE_URL"] = "http://sync.example"

        @user_a = User.create!(email: "iso-a-#{SecureRandom.hex(4)}@example.com",
                               password: "correct horse battery staple", confirmed_at: Time.current,
                               sync_device_token: "token-for-a")
        @user_b = User.create!(email: "iso-b-#{SecureRandom.hex(4)}@example.com",
                               password: "correct horse battery staple", confirmed_at: Time.current,
                               sync_device_token: "token-for-b")
      end

      teardown do
        @prior_url.nil? ? ENV.delete("CHUNK_REMOTE_URL") : ENV["CHUNK_REMOTE_URL"] = @prior_url
      end

      def token_used_for(adapter, user)
        adapter.send(:transport, user).instance_variable_get(:@token)
      end

      test "each user's transport carries only that user's own token" do
        adapter = FileLayer::ChunkRemote.new

        assert_equal "token-for-a", token_used_for(adapter, @user_a)
        assert_equal "token-for-b", token_used_for(adapter, @user_b)
      end

      # THE DETERMINISTIC REPRODUCTION OF THE OLD BUG -- NO THREADING REQUIRED. `@transport ||=`
      # is wrong even called plainly, in sequence, on one adapter: once ANYTHING has memoized onto
      # `@transport`, EVERY later call -- for ANY user -- returns that same cached object. This
      # test alone fails under the old code, every single run, with no timing dependency at all;
      # the threaded test below is the STRONGER, more faithful proof (Puma really does share this
      # instance across real threads), not a replacement for this one.
      test "asking for A after B does not hand A the previous caller's token (sequential)" do
        adapter = FileLayer::ChunkRemote.new

        first = token_used_for(adapter, @user_a)
        second = token_used_for(adapter, @user_b)
        third = token_used_for(adapter, @user_a)

        assert_equal "token-for-a", first
        assert_equal "token-for-b", second
        assert_equal "token-for-a", third,
                     "user A's SECOND request got a different token than their first -- some " \
                     "earlier call's result is being memoized across users"
      end

      # THE THREADED PROOF, AS SPECIFIED: two threads, two users, one shared adapter -- the exact
      # shape of two concurrent Puma requests against the one FileLayer.current instance. A
      # CountDownLatch (mirroring tinkerex-sync's own ConcurrentSeqTest, CLAUDE.md's recorded
      # precedent for taking a concurrency claim seriously) forces every thread to start from the
      # same instant rather than trusting scheduling luck for overlap, and each thread loops many
      # times: the old bug is not a narrow timing race that might be missed -- once ANY thread has
      # memoized, EVERY subsequent call from the LOSING user's thread observes the wrong token, so
      # a handful of iterations per thread is already an overwhelming reproduction, not a
      # best-effort one.
      test "two threads, two users: each sees only its own token, never the other's (concurrent)" do
        adapter = FileLayer::ChunkRemote.new
        threads_per_user = 4
        iterations = 50
        users = { @user_a.id => "token-for-a", @user_b.id => "token-for-b" }

        observed = Queue.new
        latch = Concurrent::CountDownLatch.new(threads_per_user * users.size)

        threads = users.keys.flat_map do |user_id|
          user = user_id == @user_a.id ? @user_a : @user_b
          threads_per_user.times.map do
            Thread.new do
              latch.count_down
              latch.wait
              iterations.times { observed << [ user_id, token_used_for(adapter, user) ] }
            end
          end
        end
        threads.each(&:join)

        assert_equal threads_per_user * users.size * iterations, observed.size

        bad = []
        bad << observed.pop until observed.empty?
        bad.reject! { |user_id, token| users.fetch(user_id) == token }

        assert_empty bad,
                     "#{bad.size} of #{threads_per_user * users.size * iterations} observations " \
                     "carried the WRONG user's token -- a shared adapter instance leaked one " \
                     "user's device credential into another user's request"
      end

      # THE ESCAPE HATCH'S OWN CONTRACT, PINNED SEPARATELY FROM THE PER-USER TESTS ABOVE. Every
      # OTHER test in this directory constructs `ChunkRemote.new(transport: some_double)` and
      # expects that double for whichever user it hands in -- this is the one test that says so
      # directly, so the constructor's own comment about "an escape hatch, not a gap" is checked,
      # not merely asserted in prose.
      test "an injected transport is returned for EVERY user, unconditionally" do
        injected = Object.new
        adapter = FileLayer::ChunkRemote.new(transport: injected)

        assert_same injected, adapter.send(:transport, @user_a)
        assert_same injected, adapter.send(:transport, @user_b)
      end
    end
  end
end
