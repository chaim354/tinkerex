require "test_helper"
require "open-uri"

module Maker
  # Edge branches of FileBytes not covered by file_bytes_test.rb: network/5xx transient
  # classification, the MAX_BYTES cap, current-version resolution (no version_id), and
  # cross-user version isolation.
  class FileBytesEdgesTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @store = Storage::ChunkStore.current
      @user  = User.create!(email: "fbe@example.com")
    end

    class StubPresignStore < Storage::ChunkStore
      def presign_get(_user_id, _hash, expires_in: 3600) = "http://stub/chunk"
    end

    def http_error(status)
      io = Struct.new(:status).new([ status.to_s, "oops" ])
      OpenURI::HTTPError.new("#{status} oops", io)
    end

    def with_http_get_raising(err)
      original = Maker::FileBytes.method(:http_get)
      Maker::FileBytes.define_singleton_method(:http_get) { |_url| raise err }
      yield
    ensure
      Maker::FileBytes.define_singleton_method(:http_get, original)
    end

    def stage_presigned(version_id:, node_id:)
      Storage::ChunkStore.current = StubPresignStore.new
      manifest_id = "m-#{version_id}"
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: "h", seq: 0, offset: 0, length: 1)
      Version.create!(user_id: @user.id, version_id:, node_id:, manifest_id:)
    end

    test "a 5xx from a presigned GET is a transient FetchError (storage outage), not missing" do
      stage_presigned(version_id: "v5", node_id: "n5")
      with_http_get_raising(http_error(503)) do
        assert_raises(Maker::FileBytes::FetchError) do
          Maker::FileBytes.read(@user, node_id: "n5", version_id: "v5")
        end
      end
    end

    test "a network error (SocketError) from a presigned GET is a transient FetchError" do
      stage_presigned(version_id: "vnet", node_id: "nnet")
      with_http_get_raising(SocketError.new("getaddrinfo failed")) do
        assert_raises(Maker::FileBytes::FetchError) do
          Maker::FileBytes.read(@user, node_id: "nnet", version_id: "vnet")
        end
      end
    end

    test "a read timeout from a presigned GET is a transient FetchError" do
      stage_presigned(version_id: "vto", node_id: "nto")
      with_http_get_raising(Net::ReadTimeout.new) do
        assert_raises(Maker::FileBytes::FetchError) do
          Maker::FileBytes.read(@user, node_id: "nto", version_id: "vto")
        end
      end
    end

    test "exceeding MAX_BYTES raises NotFound (host-protection cap)" do
      # Two oversized chunks so the running buffer trips MAX_BYTES on the second.
      half = Maker::FileBytes::MAX_BYTES / 2 + 1
      @store.write_blob(@user.id, "big1", "a" * half)
      @store.write_blob(@user.id, "big2", "b" * half)
      manifest_id = "mbig"
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: "big1", seq: 0, offset: 0, length: half)
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: "big2", seq: 1, offset: half, length: half)
      Version.create!(user_id: @user.id, version_id: "vbig", node_id: "nbig", manifest_id:)

      assert_raises(Maker::FileBytes::NotFound) do
        Maker::FileBytes.read(@user, node_id: "nbig", version_id: "vbig")
      end
    end

    test "with no version_id, read resolves the node's CURRENT version" do
      @store.write_blob(@user.id, "hc", "CURRENT")
      manifest_id = "mcur"
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: "hc", seq: 0, offset: 0, length: 7)
      version = Version.create!(user_id: @user.id, version_id: "vcur", node_id: "ncur", manifest_id:)
      @user.nodes.create!(node_id: "ncur", name: "f.svg", kind: "file", parent_node_id: "root",
                          current_version_id: version.version_id)

      bytes = Maker::FileBytes.read(@user, node_id: "ncur")
      assert_equal "CURRENT", bytes
    end

    test "a user cannot read ANOTHER user's version by node_id+version_id" do
      other = User.create!(email: "fb-other@example.com")
      Storage::ChunkStore.current = @store
      @store.write_blob(other.id, "secret", "SECRET")
      ManifestChunk.create!(user_id: other.id, manifest_id: "ms", chunk_hash: "secret",
                            seq: 0, offset: 0, length: 6)
      Version.create!(user_id: other.id, version_id: "vsec", node_id: "nsec", manifest_id: "ms")

      # @user asking for other's version => no row in @user.versions => NotFound, no bytes leak.
      assert_raises(Maker::FileBytes::NotFound) do
        Maker::FileBytes.read(@user, node_id: "nsec", version_id: "vsec")
      end
    end
  end
end
