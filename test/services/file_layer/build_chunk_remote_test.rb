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
                   "CHUNK_REMOTE_TOKEN" => "device-token" }.freeze

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
    test "it refuses to boot without a server URL and a token, naming BOTH at once" do
      build_with("LIBRARY_BACKEND" => "chunk_remote") do
        err = assert_raises(LibraryBackendCheck::Error) { FileLayer.build }
        assert_match(/CHUNK_REMOTE_URL/, err.message)
        assert_match(/CHUNK_REMOTE_TOKEN/, err.message,
                     "an operator must learn both knobs at once, not one restart at a time")
      end
    end

    test "a URL without a token is still refused, and names only what is missing" do
      build_with("LIBRARY_BACKEND" => "chunk_remote", "CHUNK_REMOTE_URL" => "http://sync.example") do
        err = assert_raises(LibraryBackendCheck::Error) { FileLayer.build }
        assert_match(/CHUNK_REMOTE_TOKEN/, err.message)
        assert_no_match(/CHUNK_REMOTE_URL,/, err.message, "it named a knob that was set")
      end
    end

    test "chunk_remote does not want the sync engine in its process" do
      # The property Arc A made possible and this backend depends on: a maker app talking to a sync
      # server over HTTP has no more use for the engine in-process than a share deployment does.
      assert_not LibraryBackend.engine_wanted?(env: { "LIBRARY_BACKEND" => "chunk_remote" }),
                 "chunk_remote must not load the engine -- it talks to one instead of being one"
    end
  end
end
