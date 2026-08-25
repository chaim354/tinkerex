# frozen_string_literal: true

require "test_helper"

module FileLayer
  # THE ARM THAT MAKES chunk_remote SELECTABLE — the last step of Stage 4, and deliberately the last.
  #
  # The adapter landed over six PRs with NO arm in FileLayer.build, so a half-built backend was never
  # reachable by any deployment: an unknown LIBRARY_BACKEND raises, which is the honest answer for
  # something that does not work yet. These tests pin both halves of that: that it is selectable now,
  # and that selecting it without configuration fails at boot rather than on someone's first request.
  class BuildChunkRemoteTest < ActiveSupport::TestCase
    def build_with(env)
      previous = FileLayer.instance_variable_get(:@current)
      FileLayer.reset!
      env.each { |k, v| ENV[k] = v }
      yield
    ensure
      env.each_key { |k| ENV.delete(k) }
      FileLayer.reset!
      FileLayer.instance_variable_set(:@current, previous)
    end

    CONFIGURED = { "LIBRARY_BACKEND" => "chunk_remote",
                   "CHUNK_REMOTE_URL" => "http://sync.example",
                   "SYNC_ADMIN_TOKEN" => "admin-token" }.freeze

    test "LIBRARY_BACKEND=chunk_remote builds the remote adapter" do
      build_with(CONFIGURED) do
        assert_instance_of FileLayer::ChunkRemote, FileLayer.build
      end
    end

    test "it declares the same capabilities selected or not -- the flag is not deployment-dependent" do
      build_with(CONFIGURED) do
        caps = FileLayer.build.capabilities
        assert caps.syncable?, "chunk_remote syncs -- that is the point of it"
        assert caps.versioned?
        assert_not caps.port_writable?, "uploads drive the two-phase presigned flow, not the port"
        assert_not caps.presignable?, "this adapter cannot safely redirect at a URL another server signed"
        assert_not caps.scannable?, "its catalog is a changelog, not a directory to poll"
      end
    end

    # THE GUARD IS CONFIG PRESENCE ONLY AND TOUCHES NO NETWORK, matching the S3 guard for the reason
    # §14a gives: a boot that depends on a third party being reachable turns a blip into a crash
    # loop. Here that would be sharper still -- a sync server being down is precisely the condition
    # chunk_remote is built to survive, since reads answer from the local mirror.
    test "it refuses to boot without a server URL and an admin token, naming BOTH at once" do
      build_with("LIBRARY_BACKEND" => "chunk_remote") do
        err = assert_raises(LibraryBackendCheck::Error) { FileLayer.build }
        assert_match(/CHUNK_REMOTE_URL/, err.message)
        assert_match(/SYNC_ADMIN_TOKEN/, err.message,
                     "an operator must learn both knobs at once, not one restart at a time")
      end
    end

    test "a URL without an admin token is still refused, and names only what is missing" do
      build_with("LIBRARY_BACKEND" => "chunk_remote", "CHUNK_REMOTE_URL" => "http://sync.example") do
        err = assert_raises(LibraryBackendCheck::Error) { FileLayer.build }
        assert_match(/SYNC_ADMIN_TOKEN/, err.message)
        assert_no_match(/CHUNK_REMOTE_URL,/, err.message, "it named a knob that was set")
      end
    end

    # THE PROPERTY THIS BACKEND WAS BUILT FOR, NOW TRUE BY CONSTRUCTION RATHER THAN BY PREDICATE.
    # It used to read `assert_not LibraryBackend.engine_wanted?(...)`; that predicate is gone with
    # the gem (Arc D Part 2), so the honest assertion is the structural one -- the engine is not in
    # this process at all, for any backend, because it is not a dependency of this app.
    #
    # NOT A TAUTOLOGY, AND WORTH KEEPING FOR EXACTLY THE REASON IT WAS WRITTEN: re-adding the gem
    # for any reason -- a stray Gemfile line, a transitive dependency, a well-meant "just for the
    # tests" -- silently puts Sync:: back in the process and returns this app to the shape Stage 5
    # spent four arcs leaving. This goes RED the moment that happens.
    test "the sync engine is not in this process at all" do
      assert_not defined?(Sync),
                 "the sync engine must not be loadable here -- chunk_remote talks to one over " \
                 "HTTP instead of being one, and no other backend has any use for it"
    end
  end
end
