require "test_helper"

module Maker
  # Maker::FileBytes is now a thin shim over the FileLayer port. What matters is that it
  # still DELEGATES and that its error constants still resolve: GeneratePreviewJob does
  # `retry_on Maker::FileBytes::FetchError` (app/jobs/maker/generate_preview_job.rb:28), so
  # if these constants ever stop resolving, preview retries break silently.
  class FileBytesTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      FileLayer.reset!
      @user = User.create!(email: "shim-#{SecureRandom.hex(4)}@example.com")
      @device = Device.register!(user: @user, name: "t")
    end
    teardown { FileLayer.reset! }

    test "error constants still resolve for GeneratePreviewJob's retry_on/rescue" do
      assert_equal FileLayer::NotFound, Maker::FileBytes::NotFound
      assert_equal FileLayer::FetchError, Maker::FileBytes::FetchError
      assert_equal FileLayer::MAX_BYTES, Maker::FileBytes::MAX_BYTES
    end

    test "read delegates to the port, mapping version_id to content_token" do
      captured = nil
      fake = Object.new
      fake.define_singleton_method(:read) do |user, node_id:, content_token: nil|
        captured = { user:, node_id:, content_token: }
        "delegated"
      end
      FileLayer.current = fake

      bytes = Maker::FileBytes.read(@user, node_id: "n1", version_id: "v1")

      assert_equal "delegated", bytes
      assert_equal @user, captured[:user]
      assert_equal "n1", captured[:node_id]
      assert_equal "v1", captured[:content_token]
    end

    # Pinned, not ambient: this is the only test in this class that is ABOUT a specific adapter —
    # it says so in its name and it stages chunk-shaped fixtures. The rest exercise the shim
    # itself (constants, delegation) and are correctly backend-agnostic, so they stay that way.
    test "read still returns real bytes end-to-end through the chunk adapter" do
      pin_file_layer_backend("chunk")
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest("real bytes")
      Storage::ChunkStore.current.put!(@user.id, hash, "real bytes")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "k.stl", base_version_id: nil, size: 10,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 10 } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_equal "real bytes", Maker::FileBytes.read(@user, node_id:)
    end

    test "an unknown node still raises the constant callers rescue" do
      assert_raises(Maker::FileBytes::NotFound) do
        Maker::FileBytes.read(@user, node_id: "nope", version_id: "nope")
      end
    end
  end
end
