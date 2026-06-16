require "test_helper"

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
  end
end
