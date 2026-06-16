require "test_helper"

module Maker
  class GeneratePreviewJobTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @store = Storage::ChunkStore.current
      @user  = User.create!(email: "job@example.com")
      @svg   = File.binread(Rails.root.join("test/fixtures/files/square.svg"))
    end

    def stage_version(node_id:, version_id:, bytes:, manifest_id: "m")
      hash = "h-#{version_id}"
      @store.write_blob(@user.id, hash, bytes)
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: hash,
                            seq: 0, offset: 0, length: bytes.bytesize)
      Version.create!(user_id: @user.id, version_id:, node_id:, manifest_id:)
    end

    test "renders SVG, attaches the asset, flips status to ready" do
      stage_version(node_id: "n1.svg", version_id: "v1", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "n1.svg", version_id: "v1", kind: "thumbnail")

      Maker::GeneratePreviewJob.perform_now(preview.id, filename: "drawing.svg")

      preview.reload
      assert_equal "ready", preview.status
      assert preview.asset.attached?
      assert_equal "image/svg+xml", preview.asset.content_type
      assert_equal @svg.b, preview.asset.download.b
      assert_nil preview.error
    end

    test "derives the extension from node_id when no filename is given" do
      stage_version(node_id: "drawing.svg", version_id: "v1", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "drawing.svg", version_id: "v1")

      Maker::GeneratePreviewJob.perform_now(preview.id)

      assert_equal "ready", preview.reload.status
    end

    test "unsupported extension flips status to unsupported (not failed), no attachment, no raise" do
      stage_version(node_id: "weird.sldprt", version_id: "v2", bytes: "anything")
      preview = @user.maker_previews.create!(node_id: "weird.sldprt", version_id: "v2")

      assert_nothing_raised do
        Maker::GeneratePreviewJob.perform_now(preview.id, filename: "weird.sldprt")
      end

      preview.reload
      assert_equal "unsupported", preview.status
      assert preview.error.present?
      assert_not preview.asset.attached?
    end

    test "a real fetch/render error flips status to failed with the error message" do
      # Version exists but its chunk bytes are missing from the store → FileBytes::NotFound.
      ManifestChunk.create!(user_id: @user.id, manifest_id: "mx", chunk_hash: "gone",
                            seq: 0, offset: 0, length: 3)
      Version.create!(user_id: @user.id, version_id: "v3", node_id: "broken.svg", manifest_id: "mx")
      preview = @user.maker_previews.create!(node_id: "broken.svg", version_id: "v3")

      Maker::GeneratePreviewJob.perform_now(preview.id, filename: "broken.svg")

      preview.reload
      assert_equal "failed", preview.status
      assert preview.error.present?
      assert_not preview.asset.attached?
    end
  end
end
