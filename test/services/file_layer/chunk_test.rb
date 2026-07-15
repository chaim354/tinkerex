require "test_helper"
require "open-uri"
require_relative "adapter_contract"

module FileLayer
  # The Chunk adapter over the sync engine's content-addressed store: this is today's
  # node -> version -> manifest_chunks -> Storage::ChunkStore read path, moved behind the port.
  class ChunkTest < ActiveSupport::TestCase
    include FileLayerAdapterContract

    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "chunk-adapter-#{SecureRandom.hex(4)}@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    # Instantiated directly, never via FileLayer.current — the adapter is tested in isolation
    # from backend selection (that's factory_test.rb's job), so this suite has no dependency
    # on the factory and can be written before it exists.
    def adapter = FileLayer::Chunk.new

    # The shared contract can only assert these are booleans — every backend answers
    # differently. Chunk's actual values matter: the UI reads them to decide whether to offer
    # Restore/History, so a flipped flag here silently removes a working feature rather than
    # failing loudly.
    test "chunk is the versioned, syncable, presignable backend" do
      caps = adapter.capabilities
      assert caps.versioned?, "chunk mode restores old versions — that's its whole point"
      assert caps.syncable?
      assert caps.presignable?
    end

    # Commit a real file and put its single chunk's bytes in the store. The contract requires
    # the created file to carry a REAL current modification time, so mtime is passed through
    # to the commit in unix NANOSECONDS (the sync engine's convention; nodes.mtime is a bigint
    # of nanos).
    def create_file!(name:, bytes:)
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest(bytes)
      Storage::ChunkStore.current.put!(@user.id, hash, bytes)
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name:, base_version_id: nil, size: bytes.bytesize,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => bytes.bytesize } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)
      node_id
    end

    # The read path's core loop walks Version#manifest_chunks, which is `.order(:seq)`
    # (app/models/version.rb). NOTHING else asserts that ordering, and getting it wrong corrupts
    # the bytes of EVERY file larger than one chunk — silently, since each chunk is individually
    # valid and hashes fine on its own. Proven by mutation: flipping to `.order(seq: :desc)`
    # passed the entire suite. Chunk-specific rather than a shared-contract test because a
    # manifest is an internal detail of the chunk store — a plain-directory Share adapter has no
    # manifest to order. create_file! always builds a SINGLE-chunk manifest, so this test builds
    # its own two-chunk one with distinct bytes.
    test "read assembles a multi-chunk manifest in seq order" do
      node_id = SecureRandom.uuid
      store = Storage::ChunkStore.current
      first, second = "AAA", "BB"
      h1 = Digest::SHA256.hexdigest(first)
      h2 = Digest::SHA256.hexdigest(second)
      store.put!(@user.id, h1, first)
      store.put!(@user.id, h2, second)
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "multi.stl", base_version_id: nil, size: 5,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [
          { "hash" => h1, "offset" => 0, "length" => 3 },
          { "hash" => h2, "offset" => 3, "length" => 2 }
        ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      # Ordered concatenation, not just "contains both": "AAABB", never "BBAAA".
      assert_equal "AAABB", adapter.read(@user, node_id:)
    end

    # --- moved from test/services/maker/{file_bytes_test,file_bytes_edges_test}.rb ---
    # These stub the presigned-GET seam, which now lives on the adapter. If they still stubbed
    # Maker::FileBytes.http_get they would silently no-op once FileBytes becomes a shim.

    # A presign-only store (no read_blob/read) forces the presigned-GET branch.
    class PresignOnlyStore
      def presign_get(_user_id, hash) = "https://example.invalid/#{hash}"
      def presign_put(_user_id, hash) = "https://example.invalid/#{hash}"
    end

    def with_http_get_raising(err)
      original = FileLayer::Chunk.method(:http_get)
      FileLayer::Chunk.define_singleton_method(:http_get) { |_url| raise err }
      yield
    ensure
      FileLayer::Chunk.define_singleton_method(:http_get, original)
    end

    def http_error(status)
      io = Struct.new(:status).new([ status.to_s, "Err" ])
      OpenURI::HTTPError.new("#{status} Err", io)
    end

    test "a 404 on the presigned GET is a missing chunk (terminal NotFound)" do
      id = create_file!(name: "e.stl", bytes: "gone")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(http_error(404)) do
        assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      end
    end

    test "a 403 on the presigned GET is TRANSIENT (FetchError, not NotFound)" do
      id = create_file!(name: "f.stl", bytes: "creds")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(http_error(403)) do
        assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      end
    end

    test "a 5xx on the presigned GET is TRANSIENT" do
      id = create_file!(name: "g.stl", bytes: "boom")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(http_error(500)) do
        assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      end
    end

    test "a network error on the presigned GET is TRANSIENT" do
      id = create_file!(name: "h.stl", bytes: "net")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(SocketError.new("no dns")) do
        assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      end
    end

    test "a timeout on the presigned GET is TRANSIENT" do
      id = create_file!(name: "i.stl", bytes: "slow")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(Net::ReadTimeout.new) do
        assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      end
    end

    test "a committed version whose chunk bytes were never stored is NotFound" do
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest("never-stored")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "phantom.stl", base_version_id: nil, size: 12,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 12 } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id:) }
    end

    test "reading with no content_token returns the CURRENT version" do
      id = create_file!(name: "j.stl", bytes: "first")
      first_token = adapter.stat(@user, node_id: id).content_token

      hash = Digest::SHA256.hexdigest("second")
      Storage::ChunkStore.current.put!(@user.id, hash, "second")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id: id, parent_node_id: nil,
        name: "j.stl", base_version_id: first_token, size: 6,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 6 } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_equal "second", adapter.read(@user, node_id: id)
      # chunk mode is the versioned backend: an OLD token still resolves. (Not a contract
      # test — share/S3 keep no history.)
      assert_equal "first", adapter.read(@user, node_id: id, content_token: first_token)
    end

    # --- additional coverage found while auditing file_bytes_edges_test.rb for completeness ---
    # These two cases (MAX_BYTES cap, cross-user isolation) are real behavior in
    # FileLayer::Chunk#read (MAX_BYTES is a FileLayer-module-level constant used identically to
    # Maker::FileBytes::MAX_BYTES; user-scoped `user.versions`/`user.nodes` lookups are the whole
    # tenant-isolation mechanism per CLAUDE.md §8) but were NOT in the task's given list of 7
    # tests to move. Dropping them when file_bytes_edges_test.rb is deleted would silently lose
    # coverage of a host-protection cap and a cross-tenant-read guard, so they're ported here too.

    test "exceeding MAX_BYTES raises NotFound (host-protection cap)" do
      # Two oversized chunks so the running buffer trips MAX_BYTES on the second.
      half = FileLayer::MAX_BYTES / 2 + 1
      store = Storage::ChunkStore.current
      hash1 = SecureRandom.hex(32)
      hash2 = SecureRandom.hex(32)
      store.put!(@user.id, hash1, "a" * half)
      store.put!(@user.id, hash2, "b" * half)
      node_id = SecureRandom.uuid
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "big.stl", base_version_id: nil, size: half * 2,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [
          { "hash" => hash1, "offset" => 0, "length" => half },
          { "hash" => hash2, "offset" => half, "length" => half }
        ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id:) }
    end

    test "a user cannot read ANOTHER user's version by node_id+content_token" do
      other = User.create!(email: "chunk-adapter-other-#{SecureRandom.hex(4)}@example.com")
      other_device = Device.register!(user: other, name: "t2")
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest("secret")
      Storage::ChunkStore.current.put!(other.id, hash, "secret")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: other, device: other_device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "secret.stl", base_version_id: nil, size: 6,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 6 } ]
      )
      other_version, = Sync::Commit.finalize(user: other, commit_id: cid)

      # @user asking for other's node_id+content_token => no row in @user's scope => NotFound,
      # no bytes leak.
      assert_raises(FileLayer::NotFound) do
        adapter.read(@user, node_id:, content_token: other_version.version_id)
      end
    end
  end
end
