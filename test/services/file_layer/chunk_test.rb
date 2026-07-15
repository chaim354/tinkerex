require "test_helper"
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
  end
end
