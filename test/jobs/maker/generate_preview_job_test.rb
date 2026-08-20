require "test_helper"

module Maker
  class GeneratePreviewJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      # Every fixture here is chunk-shaped (write_blob + ManifestChunk + Version), so this is a
      # chunk-adapter test and pins the adapter it tests rather than taking whatever
      # LIBRARY_BACKEND the process happens to carry.
      pin_file_layer_backend("chunk")
      Sync::Storage::ChunkStore.reset!
      @store = Sync::Storage::ChunkStore.current
      @user  = User.create!(email: "job@example.com")
      @svg   = File.binread(Rails.root.join("test/fixtures/files/square.svg"))
    end

    # Run the block with `renderer.available?` forced true. Hand-rolled rather than Object#stub:
    # minitest 6 DROPPED minitest/mock, so `stub` does not exist in this suite (requiring it is a
    # LoadError, not a missing-gem warning). `module_function` copies available? onto the singleton,
    # so capture-and-redefine is the restore — removing it would leave the module with no method at
    # all. The ensure is load-bearing: a leaked override would make later tests in this process
    # believe an absent toolchain is present.
    def forcing_available(renderer)
      original = renderer.method(:available?)
      renderer.define_singleton_method(:available?) { true }
      yield
    ensure
      renderer.define_singleton_method(:available?, original)
    end

    # `name:` is the file's real name on the Node row, which the job resolves when no filename
    # arg is given; it defaults to node_id because most tests here use a node_id that already
    # looks like a filename.
    def stage_version(node_id:, version_id:, bytes:, manifest_id: "m", name: nil)
      hash = "h-#{version_id}"
      @store.write_blob(@user.id, hash, bytes)
      Sync::ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: hash,
                            seq: 0, offset: 0, length: bytes.bytesize)
      version = Sync::Version.create!(user_id: @user.id, version_id:, node_id:, manifest_id:)
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

    # THE HAZARD THE ONE-ROW-PER-NODE SHAPE INTRODUCES, and the reason it needs a guard at all.
    #
    # With a row per VERSION, two quick saves made two rows and each job wrote its own — a wrong
    # thumbnail was impossible BY CONSTRUCTION, and that immunity was exactly what the extra rows
    # bought. With one row, a slow render of v1 can finish AFTER a fast render of v2 and attach
    # v1's bytes into a row that now says v2: a wrong image displayed as current, silently, which
    # is strictly worse than the leaked row this change removes.
    #
    # So the job compares-and-sets: it captures the version it is rendering and refuses to write
    # if the row moved on underneath it. Simulated by moving the row mid-run, which is what a
    # concurrent scan does.
    test "a render whose version was superseded mid-flight does NOT overwrite the newer row" do
      stage_version(node_id: "n1.svg", version_id: "v1", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "n1.svg", version_id: "v1", kind: "thumbnail")

      # The row moves to v2 while the job is between reading its target and writing its result.
      superseded = false
      hook = ->(*) { @user.maker_previews.find(preview.id).update_columns(version_id: "v2") unless superseded.tap { superseded = true } }
      Maker::Previews::Svg.singleton_class.prepend(Module.new do
        define_method(:render) { |*a, **k| hook.call; super(*a, **k) }
      end)

      forcing_available(Maker::Previews::Svg) do
        assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "drawing.svg") }
      end

      preview.reload
      assert_equal "v2", preview.version_id, "the newer version must survive the stale job"
      assert_not_equal "ready", preview.status,
                       "a v1 render must not mark the row ready — it would show v1's image as v2"
      assert_not preview.asset.attached?, "v1's bytes must not be attached to a row claiming v2"
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

    # --- the byte ceiling --------------------------------------------------------
    #
    # THE ASSERTION THAT MATTERS IS "WITHOUT READING", not "without rendering", because the cost
    # this ceiling exists to avoid is the READ: on S3 the first index of a large library enqueues
    # one of these per renderable object and each read is a full billed download — the same egress
    # §14a's identity ladder refused to pay for hashing, paid silently by previews.
    #
    # PROVED BY STAGING NO BYTES AT ALL. There is no version, no manifest and no chunk behind this
    # node, so any read attempt raises and lands the preview in `failed`. Reaching `unsupported` is
    # therefore positive evidence that the read never happened — a plain "status is unsupported"
    # assertion against a fully-staged file could not tell those two apart.
    test "a file over the preview ceiling is skipped WITHOUT reading its bytes" do
      node = stage_node(node_id: "huge.svg", version_id: "v1", name: "huge.svg")
      node.update!(size: Maker::GeneratePreviewJob::MAX_PREVIEW_BYTES + 1)
      preview = @user.maker_previews.create!(node_id: "huge.svg", version_id: "v1", kind: "thumbnail")

      forcing_available(Maker::Previews::Svg) do
        assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id) }
      end

      preview.reload
      assert_equal "unsupported", preview.status,
                   "`failed` would mean the read was attempted; `unsupported` means it was skipped"
      assert_match(/ceiling/, preview.error)
      assert_not preview.asset.attached?
    end

    # The other half — the guard must refuse the outliers, not everything.
    test "a file under the ceiling still renders normally" do
      stage_version(node_id: "small.svg", version_id: "v1", bytes: @svg, name: "small.svg")
      @user.nodes.find_by(node_id: "small.svg").update!(size: @svg.bytesize)
      preview = @user.maker_previews.create!(node_id: "small.svg", version_id: "v1", kind: "thumbnail")

      forcing_available(Maker::Previews::Svg) { Maker::GeneratePreviewJob.perform_now(preview.id) }

      assert_equal "ready", preview.reload.status
    end

    # An unknown size PROCEEDS rather than refusing. Refusing on "the catalog cannot answer" would
    # silently stop previewing files whose row is merely incomplete, and FileLayer::MAX_BYTES still
    # backstops the read — so proceeding restores the old behaviour rather than inventing a new one.
    test "a node with no recorded size is rendered, not refused" do
      stage_version(node_id: "nosize.svg", version_id: "v1", bytes: @svg, name: "nosize.svg")
      assert_nil @user.nodes.find_by(node_id: "nosize.svg").size, "fixture premise: size is unknown"
      preview = @user.maker_previews.create!(node_id: "nosize.svg", version_id: "v1", kind: "thumbnail")

      forcing_available(Maker::Previews::Svg) { Maker::GeneratePreviewJob.perform_now(preview.id) }

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
      if Maker::Previews::Svg.available?
        assert_equal "ready", preview.status
        assert_equal "image/png", preview.asset.content_type
      else
        # No embedded raster in this fixture AND no rasterizer -> Lbrn2::NoThumbnail, a plain
        # StandardError, which the job records as `failed`. Not `unsupported`: the renderer IS
        # available here (see Lbrn2#available?), this particular file just has nothing to draw
        # from. The same answer Mage gives for the same condition.
        assert_equal "failed", preview.status
      end
    end

    # THE GATE THIS ARC FIXED, DRIVEN THROUGH THE JOB RATHER THAN THE RENDERER. Asking
    # `Lbrn2.available?` directly proves nothing about what a user sees -- the job is what
    # consults the gate and what writes the terminal status, and the bug was entirely in that
    # consultation. Before the fix this row came back "unsupported" with its PNG sitting
    # unread inside the file.
    test "a LightBurn file carrying an embedded raster renders even with no rasterizer" do
      png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      xml = %(<LightBurnProject><Thumbnail Source="#{png_b64}"/><Shape Type="Rect" W="1" H="1"/></LightBurnProject>)
      stage_version(node_id: "embedded.lbrn2", version_id: "vemb", bytes: xml)
      preview = @user.maker_previews.create!(node_id: "embedded.lbrn2", version_id: "vemb", kind: "thumbnail")

      without_svg_rasterizer do
        Maker::GeneratePreviewJob.perform_now(preview.id, filename: "embedded.lbrn2")
      end

      preview.reload
      assert_equal "ready", preview.status
      assert_equal "image/png", preview.asset.content_type
    end

    test "persists parsed metadata for a LightBurn file" do
      skip "resvg not installed on this box" unless Maker::Previews::Svg.available?
      lbrn2 = File.binread(Rails.root.join("test/fixtures/files/laser-settings.lbrn2"))
      stage_version(node_id: "design.lbrn2", version_id: "vmeta", bytes: lbrn2)
      preview = @user.maker_previews.create!(node_id: "design.lbrn2", version_id: "vmeta", kind: "thumbnail")

      Maker::GeneratePreviewJob.perform_now(preview.id, filename: "design.lbrn2")

      preview.reload
      assert_equal "ready", preview.status
      assert preview.metadata.present?, "metadata stored"
      assert_equal "Fill", preview.metadata["layers"].last["mode"]
    end

    test "leaves metadata null for a non-LightBurn file" do
      # Reuses @svg (setup) under a different node_id/filename — same bytes as the
      # file's other plain-SVG tests, just staged as "logo.svg" for this assertion.
      stage_version(node_id: "logo.svg", version_id: "vlogo", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "logo.svg", version_id: "vlogo")

      Maker::GeneratePreviewJob.perform_now(preview.id, filename: "logo.svg")

      preview.reload
      assert_nil preview.metadata
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

    # The reason Mesh raises GeneratePreviewJob::Unsupported rather than its own RenderError:
    # `failed` is the state PreviewsController#create RE-ENQUEUES on a re-POST, so a client could
    # re-request forever a preview that can never succeed. This drives the real job to prove the
    # renderer-raised Unsupported reaches the terminal status — the claim in Mesh#render's comment.
    #
    # `available?` is stubbed true so this does NOT depend on f3d, which CI does not install. That
    # matters for a second reason: with f3d absent the job raises its OWN Unsupported at the
    # availability gate, so an unstubbed test would land on "unsupported" WITHOUT EVER REACHING the
    # refusal and pass for entirely the wrong reason. The error-message assertion is what pins which
    # of the two raised — the availability gate says "renderer toolchain unavailable".
    test "a renderer that refuses a kind lands in unsupported, not failed" do
      obj = File.binread(Rails.root.join("test/fixtures/files/tetra.obj"))
      stage_version(node_id: "n-glb", version_id: "vglb", bytes: obj, name: "part.obj")
      preview = @user.maker_previews.create!(node_id: "n-glb", version_id: "vglb", kind: "model_glb")

      forcing_available(Maker::Previews::Mesh) do
        assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "part.obj") }
      end

      preview.reload
      assert_equal "unsupported", preview.status, "a kind the renderer cannot produce is not a failure"
      assert_match(/cannot export GLB/, preview.error,
                   "must be Mesh's refusal, not the job's toolchain-availability gate")
      assert_not preview.asset.attached?, "nothing may be attached for a refused kind"
    end

    test "a real fetch/render error flips status to failed with the error message" do
      # Live node + version, but the chunk bytes are missing from the store → FileBytes::NotFound.
      # The node is staged deliberately: without it, read rejects the node as not-live and this
      # test would still go green while never reaching the missing-chunk path it exists to cover.
      Sync::ManifestChunk.create!(user_id: @user.id, manifest_id: "mx", chunk_hash: "gone",
                            seq: 0, offset: 0, length: 3)
      Sync::Version.create!(user_id: @user.id, version_id: "v3", node_id: "broken.svg", manifest_id: "mx")
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
