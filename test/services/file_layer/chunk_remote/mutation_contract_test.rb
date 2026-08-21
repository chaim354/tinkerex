# frozen_string_literal: true

require "test_helper"
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
        skip "the v1 sync endpoints are 501 on this backend" unless FileLayer.current.capabilities.syncable?
        Sync::Storage::ChunkStore.reset!
        @user = User.create!(email: "remote-mutation-#{SecureRandom.hex(4)}@example.com",
                             password: "correct horse battery staple", confirmed_at: Time.current)
        @device = Device.register!(user: @user, name: "loopback")
        @transport = LoopbackTransport.new(integration_session, @device.plaintext_token)
        @fetch = LoopbackFetch.new(integration_session)
      end

      # The test holds the transport rather than reaching for `adapter.transport`, which is private
      # and should stay private -- widening an adapter's API so a test can borrow its wire is how a
      # seam stops meaning anything.
      def adapter = @adapter ||= ChunkRemote.new(transport: @transport, chunk_fetch: @fetch)

      # Seeds through the ENGINE's own commit path, then pulls -- so the adapter is reading a tree
      # the server really produced rather than rows this test hand-wrote.
      def make_file(name:, bytes:)
        node_id = SecureRandom.uuid
        hash = Digest::SHA256.hexdigest(bytes)
        Sync::Storage::ChunkStore.current.put!(@user.id, hash, bytes)
        cid = SecureRandom.uuid
        Sync::Commit.begin(
          user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
          name:, base_version_id: nil, size: bytes.bytesize,
          mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
          manifest: [ { "hash" => hash, "offset" => 0, "length" => bytes.bytesize } ]
        )
        Sync::Commit.finalize(user: @user, commit_id: cid)
        # The adapter reads its MIRROR, so a row the engine just wrote is invisible until pulled --
        # which is the honest shape of a sync client and not a workaround.
        ChangelogSync.new(@user, transport: @transport).call
        node_id
      end

      def make_dir(name:) = adapter.mkdir(@user, parent_node_id: nil, name:).node_id

      def read_bytes(node_id) = adapter.read(@user, node_id:)
    end
  end
end
