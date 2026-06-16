require "test_helper"
require "open-uri"

module Maker
  class FileBytesTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @store = Storage::ChunkStore.current   # memory store in test
      @user  = User.create!(email: "fb@example.com")
    end

    test "assembles bytes from a version's ordered manifest chunks" do
      # two chunks "AAA" + "BB" -> "AAABB"
      h1, h2 = "hash1", "hash2"
      @store.write_blob(@user.id, h1, "AAA")
      @store.write_blob(@user.id, h2, "BB")
      manifest_id = "m1"
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: h1, seq: 0, offset: 0, length: 3)
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: h2, seq: 1, offset: 3, length: 2)
      Version.create!(user_id: @user.id, version_id: "v1", node_id: "n1", manifest_id:)

      bytes = Maker::FileBytes.read(@user, node_id: "n1", version_id: "v1")
      assert_equal "AAABB", bytes
    end

    test "raises when the version is unknown" do
      assert_raises(Maker::FileBytes::NotFound) do
        Maker::FileBytes.read(@user, node_id: "nope", version_id: "nope")
      end
    end

    test "raises when a chunk is missing from the store" do
      manifest_id = "m2"
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: "absent", seq: 0, offset: 0, length: 3)
      Version.create!(user_id: @user.id, version_id: "v2", node_id: "n2", manifest_id:)
      assert_raises(Maker::FileBytes::NotFound) do
        Maker::FileBytes.read(@user, node_id: "n2", version_id: "v2")
      end
    end

    # A presigning store (S3/R2/SeaweedFS) hands FileBytes a presigned GET URL that
    # open-uri fetches. The status of that GET matters: a genuine 404 means the chunk is
    # absent (terminal NotFound), but a 403/5xx/network error is TRANSIENT (auth blip,
    # storage outage) and must NOT be silently swallowed as "missing chunk" — that's the
    # exact prod failure where a 403 during a creds outage produced a misleading
    # terminal "missing chunk". A non-404 must raise a distinct FetchError so the caller
    # can RETRY rather than mark the file permanently broken.
    # A presign-only store: no read_blob/read, so FileBytes.fetch takes the presigned-GET
    # branch and the bytes come from FileBytes.http_get(url) — the seam we stub to inject
    # the HTTP failure status without standing up a real server.
    class StubPresignStore < Storage::ChunkStore
      def presign_get(_user_id, _hash, expires_in: 3600) = "http://stub/chunk"
    end

    def http_error(status)
      io = Struct.new(:status).new([ status.to_s, "oops" ])
      OpenURI::HTTPError.new("#{status} oops", io)
    end

    # Override FileBytes.http_get (the seam that performs the presigned GET) to raise the
    # given OpenURI::HTTPError, then restore the original.
    def with_http_get_raising(err)
      original = Maker::FileBytes.method(:http_get)
      Maker::FileBytes.define_singleton_method(:http_get) { |_url| raise err }
      yield
    ensure
      Maker::FileBytes.define_singleton_method(:http_get, original)
    end

    test "a 404 from a presigned GET is a genuine missing chunk (NotFound)" do
      Storage::ChunkStore.current = StubPresignStore.new
      manifest_id = "m404"
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: "h", seq: 0, offset: 0, length: 1)
      Version.create!(user_id: @user.id, version_id: "v404", node_id: "n404", manifest_id:)
      with_http_get_raising(http_error(404)) do
        assert_raises(Maker::FileBytes::NotFound) do
          Maker::FileBytes.read(@user, node_id: "n404", version_id: "v404")
        end
      end
    end

    test "a 403 from a presigned GET is a transient FetchError, not a missing chunk" do
      Storage::ChunkStore.current = StubPresignStore.new
      manifest_id = "m403"
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: "h", seq: 0, offset: 0, length: 1)
      Version.create!(user_id: @user.id, version_id: "v403", node_id: "n403", manifest_id:)
      with_http_get_raising(http_error(403)) do
        assert_raises(Maker::FileBytes::FetchError) do
          Maker::FileBytes.read(@user, node_id: "n403", version_id: "v403")
        end
      end
    end
  end
end
