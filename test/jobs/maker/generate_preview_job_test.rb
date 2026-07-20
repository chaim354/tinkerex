require "test_helper"

module Maker
  class GeneratePreviewJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      # Every fixture here is chunk-shaped (write_blob + ManifestChunk + Version), so this is a
      # chunk-adapter test and pins the adapter it tests rather than taking whatever
      # LIBRARY_BACKEND the process happens to carry.
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @store = Storage::ChunkStore.current
      @user  = User.create!(email: "job@example.com")
      @svg   = File.binread(Rails.root.join("test/fixtures/files/square.svg"))
    end

    # `name:` is the file's real name on the Node row, which the job resolves when no filename
    # arg is given; it defaults to node_id because most tests here use a node_id that already
    # looks like a filename.
    def stage_version(node_id:, version_id:, bytes:, manifest_id: "m", name: nil)
      hash = "h-#{version_id}"
      @store.write_blob(@user.id, hash, bytes)
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: hash,
                            seq: 0, offset: 0, length: bytes.bytesize)
      version = Version.create!(user_id: @user.id, version_id:, node_id:, manifest_id:)
      # A preview always belongs to a real, live node in production — FileLayer#read now
      # enforces that (tombstoned = gone), so the fixture has to reflect reality.
      stage_node(node_id:, version_id:, name:)
      version
    end

    def stage_node(node_id:, version_id:, name: nil)
      node = @user.nodes.find_or_initialize_by(node_id:)
      node.update!(name: name || node_id, kind: "file", deleted: false,
                   current_version_id: version_id)
      node
    end

    test "renders SVG to a PNG when resvg is present; unsupported when absent" do
      stage_version(node_id: "n1.svg", version_id: "v1", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "n1.svg", version_id: "v1", kind: "thumbnail")

      assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "drawing.svg") }

      preview.reload
      if Maker::Previews::Svg.available?
        assert_equal "ready", preview.status
        assert_equal "image/png", preview.asset.content_type
        assert_equal "\x89PNG".b, preview.asset.download[0, 4].b
      else
        assert_equal "unsupported", preview.status
        assert_not preview.asset.attached?
      end
    end

    test "derives the extension from node_id when no filename is given" do
      # 3MF (embedded-thumbnail extract) is always available (pure Ruby), so this orchestration
      # test — about resolving the extension from node_id — does not depend on the resvg toolchain.
      threemf = File.binread(Rails.root.join("test/fixtures/files/cube.3mf"))
      stage_version(node_id: "drawing.3mf", version_id: "v1", bytes: threemf)
      preview = @user.maker_previews.create!(node_id: "drawing.3mf", version_id: "v1")

      Maker::GeneratePreviewJob.perform_now(preview.id)

      assert_equal "ready", preview.reload.status
    end

    test "no filename: resolves the renderable name from the Node row (extensionless node_id)" do
      # The regression the smoke caught: node_id is a UUID with no extension, but the
      # synced Node row carries the real name. With no filename arg, the job must resolve
      # the name from the node (not fall back to the extensionless node_id). Uses the
      # always-available 3MF renderer so this stays a pure orchestration test.
      node_id = "11111111-2222-3333-4444-555555555555"
      threemf = File.binread(Rails.root.join("test/fixtures/files/cube.3mf"))
      stage_version(node_id:, version_id: "v1", bytes: threemf, name: "drawing.3mf")
      preview = @user.maker_previews.create!(node_id:, version_id: "v1", kind: "thumbnail")

      Maker::GeneratePreviewJob.perform_now(preview.id)

      preview.reload
      assert_equal "ready", preview.status
      assert preview.asset.attached?
      assert_equal "image/png", preview.asset.content_type
      assert_nil preview.error
    end

    test "no filename: node name with an unrenderable extension stays unsupported" do
      node_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      stage_version(node_id:, version_id: "v2", bytes: "anything", name: "part.sldprt")
      preview = @user.maker_previews.create!(node_id:, version_id: "v2")

      assert_nothing_raised do
        Maker::GeneratePreviewJob.perform_now(preview.id)
      end

      preview.reload
      assert_equal "unsupported", preview.status
      assert preview.error.present?
      assert_not preview.asset.attached?
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

    test "a job for a since-deleted preview is discarded, not failed" do
      stage_version(node_id: "gone.svg", version_id: "vg", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "gone.svg", version_id: "vg")
      id = preview.id
      preview.destroy!

      assert_nothing_raised do
        Maker::GeneratePreviewJob.perform_now(id, filename: "gone.svg")
      end

      assert_not Maker::Preview.exists?(id)
    end

    test "a transient FetchError is retried, NOT marked terminally failed" do
      # A 403/5xx/network blip reaching the chunk store surfaces as FileBytes::FetchError.
      # The chunk may well exist — we just couldn't read it this instant — so the job must
      # re-raise (ActiveJob retries) and leave the preview NON-terminal (processing),
      # rather than burning it to "failed". This is the prod creds-outage scenario.
      stage_version(node_id: "flaky.svg", version_id: "vf", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "flaky.svg", version_id: "vf")

      original = Maker::FileBytes.method(:read)
      Maker::FileBytes.define_singleton_method(:read) do |*, **|
        raise Maker::FileBytes::FetchError, "HTTP 403 transient"
      end

      begin
        # retry_on re-enqueues the job (it does NOT mark it failed). Under the test
        # adapter the retry is enqueued rather than re-run, so assert a retry was queued.
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::GeneratePreviewJob.perform_now(preview.id, filename: "flaky.svg")
        end
      ensure
        Maker::FileBytes.define_singleton_method(:read, original)
      end

      preview.reload
      assert_not_equal "failed", preview.status, "transient error must not be terminal"
      assert_not preview.asset.attached?
    end

    test "renders a 3MF by extracting its embedded thumbnail → ready PNG" do
      threemf = File.binread(Rails.root.join("test/fixtures/files/cube.3mf"))
      stage_version(node_id: "cube.3mf", version_id: "v3mf", bytes: threemf)
      preview = @user.maker_previews.create!(node_id: "cube.3mf", version_id: "v3mf")

      Maker::GeneratePreviewJob.perform_now(preview.id, filename: "cube.3mf")

      preview.reload
      assert_equal "ready", preview.status
      assert preview.asset.attached?
      assert_equal "image/png", preview.asset.content_type
      assert_equal "\x89PNG".b, preview.asset.download[0, 4].b
    end

    test "a 3MF with neither an embedded thumbnail nor a mesh flips to failed" do
      # nothumb.3mf has no embedded PNG and no <mesh>, so both the thumbnail and the mesh-render
      # fallback fail. (A 3MF with a mesh renders via the STL thumbnailer — see three_mf_test.)
      nothumb = File.binread(Rails.root.join("test/fixtures/files/nothumb.3mf"))
      stage_version(node_id: "bare.3mf", version_id: "vbare", bytes: nothumb)
      preview = @user.maker_previews.create!(node_id: "bare.3mf", version_id: "vbare")

      assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "bare.3mf") }

      preview.reload
      assert_equal "failed", preview.status
      assert preview.error.present?
      assert_not preview.asset.attached?
    end

    test "renders a LightBurn .lbrn2 to PNG when resvg is present; unsupported when absent" do
      lbrn2 = File.binread(Rails.root.join("test/fixtures/files/sample.lbrn2"))
      stage_version(node_id: "art.lbrn2", version_id: "vlb", bytes: lbrn2)
      preview = @user.maker_previews.create!(node_id: "art.lbrn2", version_id: "vlb")

      assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "art.lbrn2") }

      preview.reload
      if Maker::Previews::Lbrn2.available?
        assert_equal "ready", preview.status
        assert_equal "image/png", preview.asset.content_type
      else
        assert_equal "unsupported", preview.status
      end
    end

    test "renders a DXF to PNG when resvg is present; unsupported when absent" do
      dxf = File.binread(Rails.root.join("test/fixtures/files/sample.dxf"))
      stage_version(node_id: "plate.dxf", version_id: "vdxf", bytes: dxf)
      preview = @user.maker_previews.create!(node_id: "plate.dxf", version_id: "vdxf")

      assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "plate.dxf") }

      preview.reload
      if Maker::Previews::Dxf.available?
        assert_equal "ready", preview.status
        assert_equal "image/png", preview.asset.content_type
      else
        assert_equal "unsupported", preview.status
      end
    end

    test "an STL preview renders via the euc Stl renderer (unsupported only if its binary is absent)" do
      # STL no longer depends on F3D — it uses the pure-CPU stl-thumbnailer (Maker::Previews::Stl,
      # no GL/Mesa). When the binary is present the job renders a PNG; when absent it marks
      # `unsupported` (a deliberate terminal state), never crashing.
      stl = File.binread(Rails.root.join("test/fixtures/files/tetra.stl"))
      stage_version(node_id: "cube.stl", version_id: "vstl", bytes: stl)
      preview = @user.maker_previews.create!(node_id: "cube.stl", version_id: "vstl")

      assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "cube.stl") }

      preview.reload
      if Maker::Previews::Stl.available?
        assert_equal "ready", preview.status
        assert_equal "image/png", preview.asset.content_type
      else
        assert_equal "unsupported", preview.status
        assert preview.error.present?
        assert_not preview.asset.attached?
      end
    end

    test "a real fetch/render error flips status to failed with the error message" do
      # Live node + version, but the chunk bytes are missing from the store → FileBytes::NotFound.
      # The node is staged deliberately: without it, read rejects the node as not-live and this
      # test would still go green while never reaching the missing-chunk path it exists to cover.
      ManifestChunk.create!(user_id: @user.id, manifest_id: "mx", chunk_hash: "gone",
                            seq: 0, offset: 0, length: 3)
      Version.create!(user_id: @user.id, version_id: "v3", node_id: "broken.svg", manifest_id: "mx")
      stage_node(node_id: "broken.svg", version_id: "v3")
      preview = @user.maker_previews.create!(node_id: "broken.svg", version_id: "v3")

      Maker::GeneratePreviewJob.perform_now(preview.id, filename: "broken.svg")

      preview.reload
      assert_equal "failed", preview.status
      # Pins WHICH failure: without this, deleting the stage_node line above would leave the
      # test green on that error, silently losing the missing-chunk coverage.
      assert_match(/missing chunk/, preview.error.to_s)
      assert_not preview.asset.attached?
    end
  end
end
