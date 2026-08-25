require "test_helper"

module Maker
  # Maker::FileBytes is now a thin shim over the FileLayer port. What matters is that it
  # still DELEGATES and that its error constants still resolve: GeneratePreviewJob does
  # `retry_on Maker::FileBytes::FetchError` (app/jobs/maker/generate_preview_job.rb:28), so
  # if these constants ever stop resolving, preview retries break silently.
  class FileBytesTest < ActiveSupport::TestCase
    setup do
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

    # THE ONE TEST HERE THAT IS ABOUT A REAL ADAPTER RATHER THAN THE SHIM. It used to stage
    # chunk-shaped fixtures through Sync::Commit and said so in its name; with the engine retired
    # it stages a real file in a real share library instead. The claim is unchanged and is the one
    # worth keeping: FileBytes is a thin shim over the port, and the other tests here prove
    # delegation with a double, which cannot catch the shim delegating correctly to a port that
    # then cannot actually produce bytes.
    test "read still returns real bytes end-to-end through a real adapter" do
      root = use_fresh_share_library!
      begin
        node_id = SecureRandom.uuid
        root.join("k.stl").binwrite("real bytes")
        @user.nodes.create!(node_id:, name: "k.stl", kind: "file", deleted: false,
                            storage_path: "k.stl", size: 10,
                            content_hash: Digest::SHA256.hexdigest("real bytes"))

        assert_equal "real bytes", Maker::FileBytes.read(@user, node_id:)
      ensure
        FileLayer.reset!
        FileUtils.remove_entry(root) if root&.exist?
      end
    end

    test "an unknown node still raises the constant callers rescue" do
      assert_raises(Maker::FileBytes::NotFound) do
        Maker::FileBytes.read(@user, node_id: "nope", version_id: "nope")
      end
    end
  end
end
