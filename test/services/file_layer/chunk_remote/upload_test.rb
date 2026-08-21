# frozen_string_literal: true

require "test_helper"

module FileLayer
  class ChunkRemote
    # THE TWO-PHASE UPLOAD, DRIVEN AGAINST THE REAL ENGINE — same reasoning as the mutation contract:
    # what is under test here is a protocol the SERVER owns (which chunks it already has, when a
    # finalize is refused for missing bytes), and a fake would only confirm this adapter's guesses.
    class UploadTest < ActionDispatch::IntegrationTest
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
          body = parse
          return body if code.between?(200, 299)

          # Mirrors Transport's own mapping, INCLUDING the chunks_missing arm -- if this diverged,
          # the suite would be exercising a translation that does not ship.
          raise FileLayer::ChunksMissing, Array(body["missing"]) if body["error"] == "chunks_missing"

          msg = (body["error"] || "HTTP #{code}").to_s
          case code
          when 404 then raise FileLayer::NotFound, msg
          when 409, 422, 501 then raise FileLayer::UnsupportedOperation, msg
          else raise FileLayer::FetchError, msg
          end
        end

        def parse = JSON.parse(@s.response.body) rescue {}
      end

      # Fetches a presigned chunk URL through the session: a memory-backed store presigns a
      # RELATIVE path (it points at Rails itself), which has no host to open a socket to in-process.
      class LoopbackFetch
        def initialize(session) = @s = session

        def get(url)
          uri = URI.parse(url)
          @s.get(uri.respond_to?(:request_uri) ? uri.request_uri : url)
          raise FileLayer::FetchError, "storage answered #{@s.response.status}" unless @s.response.status == 200

          @s.response.body.b
        end
      end

      setup do
        skip "the v1 sync endpoints are 501 on this backend" unless FileLayer.current.capabilities.syncable?
        Sync::Storage::ChunkStore.reset!
        @user = User.create!(email: "remote-upload-#{SecureRandom.hex(4)}@example.com",
                             password: "correct horse battery staple", confirmed_at: Time.current)
        @device = Device.register!(user: @user, name: "loopback")
        @transport = LoopbackTransport.new(integration_session, @device.plaintext_token)
        @adapter = ChunkRemote.new(transport: @transport, chunk_fetch: LoopbackFetch.new(integration_session))
      end

      def manifest_for(bytes)
        [ { "hash" => Digest::SHA256.hexdigest(bytes), "offset" => 0, "length" => bytes.bytesize } ]
      end

      test "begin_upload reports the chunks the server does not have" do
        bytes = "brand new content"
        begun = @adapter.begin_upload(@user, name: "new.stl", size: bytes.bytesize,
                                      manifest: manifest_for(bytes), device: @device)

        assert begun.commit_id.present?
        assert begun.node_id.present?, "the node_id is minted client-side and must come back"
        assert_includes begun.missing, Digest::SHA256.hexdigest(bytes),
                        "a chunk the server has never seen must be reported missing"
      end

      test "a chunk the server already holds is NOT reported missing" do
        bytes = "already there"
        hash = Digest::SHA256.hexdigest(bytes)
        Sync::Storage::ChunkStore.current.put!(@user.id, hash, bytes)
        @user.chunks.create!(chunk_hash: hash, size: bytes.bytesize, refcount: 1)

        begun = @adapter.begin_upload(@user, name: "dedup.stl", size: bytes.bytesize,
                                      manifest: manifest_for(bytes), device: @device)
        assert_not_includes begun.missing, hash, "dedup is the whole point of a content-addressed store"
      end

      test "finalize refuses with ChunksMissing, carrying the hashes, when bytes were never put" do
        # THE ARM THAT NEEDED ITS OWN MAPPING. The server answers 422 with `error: chunks_missing`,
        # which the generic 422 rule would flatten into UnsupportedOperation and discard the hashes --
        # the one piece of information the caller needs to recover (upload those, finalize again).
        bytes = "never uploaded"
        begun = @adapter.begin_upload(@user, name: "missing.stl", size: bytes.bytesize,
                                      manifest: manifest_for(bytes), device: @device)

        err = assert_raises(FileLayer::ChunksMissing) do
          @adapter.finalize_upload(@user, commit_id: begun.commit_id)
        end
        assert_includes err.hashes, Digest::SHA256.hexdigest(bytes)
      end

      test "a full round trip: begin, put the bytes, finalize, then read them back" do
        bytes = "round trip payload"
        hash = Digest::SHA256.hexdigest(bytes)
        begun = @adapter.begin_upload(@user, name: "trip.stl", size: bytes.bytesize,
                                      manifest: manifest_for(bytes), device: @device)

        # The caller puts bytes at storage itself -- neither this app nor the sync server touches
        # them, which is §15 in remote mode.
        Sync::Storage::ChunkStore.current.put!(@user.id, hash, bytes)

        finalized = @adapter.finalize_upload(@user, commit_id: begun.commit_id)
        assert finalized.version_id.present?
        assert_equal "trip.stl", finalized.info.name,
                     "info comes from the mirror, so finalize must have pulled before building it"
        assert_equal bytes.bytesize, finalized.info.size

        # AND THE BYTES COME BACK. An earlier draft of this line was
        # `assert_equal bytes, @adapter.read(...) rescue nil`, which asserts nothing at all -- the
        # rescue swallowed the very failure it was written to catch. Kept as a note because that is
        # the shape this repo keeps finding: an assertion that cannot fail is worse than none.
        assert_equal bytes, @adapter.read(@user, node_id: begun.node_id)
      end

      test "finalize pulls, so the mirror carries the new version" do
        bytes = "mirrored"
        hash = Digest::SHA256.hexdigest(bytes)
        begun = @adapter.begin_upload(@user, name: "mirror.stl", size: bytes.bytesize,
                                      manifest: manifest_for(bytes), device: @device)
        Sync::Storage::ChunkStore.current.put!(@user.id, hash, bytes)
        finalized = @adapter.finalize_upload(@user, commit_id: begun.commit_id)

        node = @user.nodes.find_by(node_id: begun.node_id)
        assert_equal finalized.version_id, node.current_version_id
        assert_equal 1, RemoteManifestChunk.where(user_id: @user.id, version_id: finalized.version_id).count,
                     "the pull must have stored the manifest, or the file cannot be read back"
      end
    end
  end
end
