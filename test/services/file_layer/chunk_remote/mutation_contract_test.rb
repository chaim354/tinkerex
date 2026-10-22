# frozen_string_literal: true

require "test_helper"
require "support/chunk_remote_journey"
require_relative "../adapter_mutation_contract"

module FileLayer
  class ChunkRemote
    # THE MUTATION CONTRACT, RUN AGAINST THE REAL ENGINE — not a fake sync server.
    #
    # WHY THIS ONE DOES NOT USE A SOCKET FAKE, WHERE THE READ CONTRACT DOES. These nine tests are
    # about SEMANTICS the server owns: cross-kind refusal, cycle rejection, tombstone-not-destroy,
    # subtree cascade, restoring the same node_id. A fake would have to reimplement all of it, and a
    # fake that shares this adapter's assumptions confirms them rather than checking them —
    # §14e's FakeS3 lesson, where inverse encodings kept 79/80 tests green over silent data loss.
    #
    # So the transport dispatches into THIS app's own v1 endpoints, which on the chunk leg are the
    # engine's real controllers running Sync::Mutation, Sync::SubtreeDelete and Sync::Trash. The
    # WIRE is simulated; everything the wire reaches is real, which is the half that matters.
    class MutationContractTest < ActionDispatch::IntegrationTest
      include FileLayerMutationContract

      # Transport-shaped, but dispatching in-process. Mirrors Transport's error mapping so the
      # adapter meets the same vocabulary it would over a socket -- if these diverged, this suite
      # would be testing a translation layer that does not ship.
      class LoopbackTransport
        def initialize(session, token) = (@s = session; @token = token)

        def get(path, params = {}) = run { @s.get(path, params:, headers: auth) }
        def post(path, body = {}) = run { @s.post(path, params: body, headers: auth) }
        def delete(path) = run { @s.delete(path, headers: auth) }

        private

        def auth = { "Authorization" => "Bearer #{@token}" }

        def run
          yield
          code = @s.response.status
          return parse if code.between?(200, 299)

          msg = (parse["error"] || "HTTP #{code}").to_s
          case code
          when 404      then raise FileLayer::NotFound, msg
          when 409, 422, 501 then raise FileLayer::UnsupportedOperation, msg
          else raise FileLayer::FetchError, msg
          end
        end

        def parse = JSON.parse(@s.response.body) rescue {}
      end

      # Fetches a presigned chunk URL through the integration session, because a memory-backed sync
      # server presigns URLs RAILS serves -- which have no host to open a socket to in-process. This
      # is the same substitution the transport gets, for the other half of the round trip.
      class LoopbackFetch
        def initialize(session) = @s = session

        def get(url)
          # A memory- or local-backed store presigns a RELATIVE path (no scheme, no host), because
          # the URL points at Rails itself -- which is precisely why ChunkRemote refuses to redirect
          # a browser at one (see CAPABILITIES). URI::Generic has no #request_uri, so handle both.
          uri = URI.parse(url)
          @s.get(uri.respond_to?(:request_uri) ? uri.request_uri : url)
          raise FileLayer::FetchError, "chunk storage answered #{@s.response.status}" unless @s.response.status == 200

          @s.response.body.b
        end
      end

      setup do
        # SKIPS ON THE CAPABILITY, NOT ON `defined?(Sync)`. The engine is LOADED on all three backend
        # legs (they pin SYNC_ENGINE=1 so their counts stay identical), but its v1 endpoints are
        # `syncable`-gated and answer 501 on share and s3 -- so the loopback got
        # UnsupportedOperation from the wire rather than from anything this adapter decided. The
        # engine being present and its endpoints being live are two different questions.
        # READS ENV, NOT FileLayer.current, AND THE DIFFERENCE IS ORDER-DEPENDENCE.
        # `FileLayer.current` is global mutable state -- test_helper's `pin_file_layer_backend`
        # swaps it, so in the full parallel suite whether this skipped depended on what had run
        # before it in the same worker. In isolation these files were perfectly deterministic;
        # the flap only appeared in the whole-suite counts, which is the hardest place to see it.
        # LibraryBackendCheck.configured re-reads ENV on every call and nothing mutates it, so this
        # asks the same question of something stable.
        # THESE RAN ONLY ON THE CHUNK LEG, AND CHUNK IS GONE (Arc D Part 2). The skip used to read
        # `unless LibraryBackend.name == "chunk"` because the rig below is a LOOPBACK: it pointed
        # the adapter's transport at this same Rails process, using the embedded engine's own v1
        # endpoints as a stand-in for a standalone sync server. With the engine retired there is no
        # in-process server to loop back to, so the only honest place for these is the
        # `test-chunk-remote` gate, which boots a real one via bin/sync-server.
        #
        # SKIPPING ON WHETHER A SERVER IS CONFIGURED, NOT ON `defined?(Sync)` -- §14j's recorded
        # trap is a guard that skips on the very thing it asserts, which reports success having
        # asserted nothing. A configured server is a PRECONDITION, and the gate's own CI step
        # greps its output for skips so this cannot quietly become a no-op there.
        skip "needs a real sync server (bin/sync-server start); runs in the test-chunk-remote gate" \
          unless ChunkRemoteJourney.configured? && LibraryBackendCheck.configured == "chunk_remote"
        @user = User.create!(email: "remote-mutation-#{SecureRandom.hex(4)}@example.com",
                             password: "correct horse battery staple", confirmed_at: Time.current)
      end

      # THE REAL ADAPTER AGAINST THE REAL SERVER, where this used to build one over a LOOPBACK
      # transport pointed at this same Rails process. That worked while the embedded engine served
      # /v1/commit and friends here; it does not now, and reconstructing a fake would test the fake.
      # FileLayer.current is already a ChunkRemote configured from the env bin/sync-server wrote.
      def adapter = FileLayer.current

      # SEEDS THROUGH THE PORT'S OWN UPLOAD VERBS, so the adapter reads a tree the SERVER really
      # produced rather than rows this test hand-wrote -- the same property the old Sync::Commit
      # seeding had, obtained the way a real client obtains it. `refresh!` is implicit: every one
      # of these verbs pulls the changelog on the way out (§14a), so the local mirror already
      # reflects the commit by the time this returns.
      def make_file(name:, bytes:)
        hash = Digest::SHA256.hexdigest(bytes)
        begun = adapter.begin_upload(@user, name:, size: bytes.bytesize,
                                     manifest: [ { hash:, offset: 0, length: bytes.bytesize } ])
        begun.missing.each { |h| adapter.put_chunk(@user, begun:, hash: h, bytes:) }
        adapter.finalize_upload(@user, commit_id: begun.commit_id)
        # THE NODE_ID, NOT THE NODE. adapter_mutation_contract.rb's own header says make_file
        # "returns its node_id", and make_dir beside this already does -- hand back a Node and
        # every contract call passes an AR object where a String belongs, so live_node!'s
        # find_by(node_id: <Node>) misses and the failure reads `FileLayer::NotFound: node
        # #<Node id: 1, ...>` rather than anything about the shape of the return value.
        begun.node_id
      end

      def make_dir(name:) = adapter.mkdir(@user, parent_node_id: nil, name:).node_id

      def read_bytes(node_id) = adapter.read(@user, node_id:)
    end
  end
end
