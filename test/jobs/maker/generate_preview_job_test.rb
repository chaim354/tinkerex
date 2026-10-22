require "test_helper"

module Maker
  class GeneratePreviewJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      # A FRESH SHARE LIBRARY, NOT THE CHUNK STORE. Every fixture here used to be chunk-shaped
      # (write_blob + ManifestChunk + Version rows) and the suite pinned embedded chunk to match;
      # with the engine retired there is no in-process store to write a blob into. What these tests
      # are actually about is the JOB -- compare-and-set on a superseded version, renderer
      # revisions, unsupported types, missing bytes -- none of which is a claim about which backend
      # holds them.
      @root  = use_fresh_share_library!
      @user  = User.create!(email: "job@example.com")
      @svg   = File.binread(Rails.root.join("test/fixtures/files/square.svg"))
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
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
    # THE FAKE version_id IS ALSO WRITTEN AS THE NODE'S content_hash, AND THAT IS THE WHOLE TRICK.
    # These tests deliberately choose their own version ids ("v1", "v2", ...) to drive the job's
    # compare-and-set — a slow render of v1 finishing after v2 must not attach v1's bytes to a row
    # claiming v2 (§14b). On share, `content_token` IS the node's content_hash, and Share#read
    # REFUSES a token that is not current rather than silently serving current bytes, precisely
    # because previews key on that token. So writing version_id into content_hash is not a fudge:
    # it makes the fixture's chosen token genuinely be this file's content token, which is what
    # the chunk-shaped Version row used to do.
    def stage_version(node_id:, version_id:, bytes:, manifest_id: "m", name: nil)
      filename = name || node_id
      path = @root.join(filename)
      path.dirname.mkpath
      path.binwrite(bytes)
      stage_node(node_id:, version_id:, name:, storage_path: filename)
    end

    def stage_node(node_id:, version_id:, name: nil, storage_path: nil)
      node = @user.nodes.find_or_initialize_by(node_id:)
      node.update!(name: name || node_id, kind: "file", deleted: false,
                   current_version_id: version_id, content_hash: version_id,
                   storage_path: storage_path || name || node_id)
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
      # CAPTURE AND RESTORE, NEVER `prepend`. This hook was once a prepended module, which cannot be
      # taken off: it outlived this test and wrapped `Svg.render` as `(*a, **k)` for the rest of the
      # process. `Registry.render` passes `kind:` only to a renderer whose signature DECLARES it, so
      # every later SVG geometry render silently became a PNG thumbnail -- seed-dependent, red only
      # when this test ran first.
      original = Maker::Previews::Svg.method(:render)
      Maker::Previews::Svg.define_singleton_method(:render) { |*a, **k| hook.call; original.call(*a, **k) }

      forcing_available(Maker::Previews::Svg) do
        assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "drawing.svg") }
      end

      preview.reload
      assert_equal "v2", preview.version_id, "the newer version must survive the stale job"
      assert_not_equal "ready", preview.status,
                       "a v1 render must not mark the row ready — it would show v1's image as v2"
      assert_not preview.asset.attached?, "v1's bytes must not be attached to a row claiming v2"
    ensure
      Maker::Previews::Svg.define_singleton_method(:render, original) if original
    end

    # --- the start transition (F-S08-2) ------------------------------------------------------
    #
    # Asked from INSIDE the render, because that is the only place the in-between state exists:
    # before it the job has not started, after it the terminal write has landed.

    CUBE_3MF = File.binread(Rails.root.join("test/fixtures/files/cube.3mf")).freeze
    OLD_PICTURE = "\x89PNG old build".b.freeze

    # `look` runs inside the job's render, then the render happens for real. Registry.render is the
    # one call every renderer is reached through; captured and restored, never prepended (the test
    # above says why).
    def during_render(look)
      original = Maker::Previews::Registry.method(:render)
      Maker::Previews::Registry.define_singleton_method(:render) { |*a, **k| look.call; original.call(*a, **k) }
      yield
    ensure
      Maker::Previews::Registry.define_singleton_method(:render, original)
    end

    # The row moves on AFTER the job has read it and BEFORE its first write — the window the start
    # transition used to write through blind. One-shot, so the job's own later reads see the truth.
    def moving_the_row_after_the_job_reads_it(id, **columns)
      original = Maker::Preview.method(:find)
      moved = false
      Maker::Preview.define_singleton_method(:find) do |*args|
        found = original.call(*args)
        Maker::Preview.where(id:).update_all(columns) unless moved
        moved = true
        found
      end
      yield
    ensure
      Maker::Preview.singleton_class.remove_method(:find)
    end

    def threemf_row!(node_id, status:, revision: Maker::Previews::ThreeMf::THUMBNAIL_REVISION, picture: true)
      stage_version(node_id:, version_id: "v1", bytes: CUBE_3MF)
      row = @user.maker_previews.create!(node_id:, version_id: "v1", kind: "thumbnail", status:,
                                         renderer_revision: revision)
      row.asset.attach(io: StringIO.new(OLD_PICTURE), filename: "old.png", content_type: "image/png") if picture
      row
    end

    # THE DEFECT, END TO END: a renderer bump on a row with a picture. Enqueue leaves it showing
    # (`rebuilding`), and the job's start must not take that back — it used to write `processing`
    # over it, so every surface drew a spinner over a correct picture for the whole render.
    test "a renderer rebuild keeps the old picture up through its whole render" do
      row = threemf_row!("cube.3mf", status: "ready",
                         revision: Maker::Previews::ThreeMf::THUMBNAIL_REVISION - 1)
      Maker::Previews::Enqueue.call(user: @user, node_id: "cube.3mf", name: "cube.3mf", version_id: "v1")

      seen = nil
      during_render(-> { live = Maker::Preview.find(row.id); seen = [ live.showable?, live.in_flight? ] }) do
        Maker::GeneratePreviewJob.perform_now(row.id)
      end

      assert_equal [ true, true ], seen,
                   "mid-render the row must still show its picture AND still be a job in flight"
      row.reload
      assert row.current_build?, "the rebuild did not land as the current build: #{row.status}"
      assert_not_equal OLD_PICTURE, row.asset.download.b, "the new build did not replace the old picture"
    end

    # THE TRANSITION TABLE. `pending → processing` is the one move the start makes: it is the v1
    # wire's "a worker has it" and restarts the stall clock. Every other status the job can find
    # already says something true about what is on screen, so the start leaves it alone — `ready`
    # included, which a duplicate job used to blank for a render that changes nothing.
    test "the start moves a pending row to processing and leaves every other status alone" do
      { "pending" => "processing", "rebuilding" => "rebuilding", "ready" => "ready" }.each do |start, during|
        row = threemf_row!("#{start}.3mf", status: start, picture: start != "pending")

        seen = nil
        during_render(-> { seen = Maker::Preview.find(row.id).status }) do
          Maker::GeneratePreviewJob.perform_now(row.id)
        end

        assert_equal during, seen, "a #{start} row read #{seen.inspect} while its job rendered"
        assert_equal "ready", row.reload.status
      end
    end

    # A REBUILD THAT FAILS IS `failed`: THE OLD PICTURE COMES DOWN AND NO READ DOOR RETRIES IT. The
    # asset stays attached, but no surface shows it — a failed render is the honest answer, not an
    # older build kept up as if nothing happened — and `failed` is outside `IN_FLIGHT`, so the stall
    # heal cannot turn a broken renderer into one doomed job per page view, however old the row gets.
    test "a rebuild whose render raises goes failed, shows nothing, and is not retried by a read door" do
      row = threemf_row!("broken.3mf", status: "rebuilding")

      during_render(-> { raise "renderer bug" }) { Maker::GeneratePreviewJob.perform_now(row.id) }

      row.reload
      assert_equal [ true, false, false ], [ row.failed?, row.showable?, row.in_flight? ],
                   "failed?, showable?, in_flight? after a rebuild's render raised"
      row.update_column(:updated_at, 3.days.ago)
      assert_not Maker::Previews::Enqueue.needs_job?(row.reload, version_id: "v1",
                                                     revision: Maker::Previews::ThreeMf::THUMBNAIL_REVISION,
                                                     retry_failed: false),
                 "a read door would re-enqueue a failed rebuild on every view"
    end

    # THE START IS COMPARE-AND-SET LIKE EVERY OTHER WRITE THIS JOB MAKES. It was a bare `update!` on
    # the row as the job first read it, so a row that moved on in between was overwritten: here a
    # renderer bump lands on it, and the stale object's `pending → processing` flipped the newer
    # `rebuilding` row and blanked its picture — and the job then rendered for coordinates nobody
    # had asked for. Whoever moved the row enqueued the job for what it names now.
    test "a job whose row moved on before its first write leaves the row alone" do
      row = threemf_row!("moved.3mf", status: "pending", picture: false)

      rendered = false
      moving_the_row_after_the_job_reads_it(row.id, renderer_revision: 99, status: "rebuilding") do
        during_render(-> { rendered = true }) { Maker::GeneratePreviewJob.perform_now(row.id) }
      end

      row.reload
      assert_equal "rebuilding", row.status, "a job holding a superseded read flipped the newer row"
      assert_equal 99, row.renderer_revision
      assert_not rendered, "the job rendered for coordinates the row no longer names"
    end

    # NEVER OVER A PICTURE THE MAKER CHOSE (2026-10-20). A render queued before they clicked "Use
    # this view as preview" runs after the click: the row is `viewer` now, and the job stands down
    # rather than attaching its own render over their angle. A 3MF, because its embedded thumbnail
    # renders on any box — so a job that did NOT stand down would really replace the asset here.
    test "a render queued before the maker chose a view does not land on top of it" do
      row = threemf_row!("chosen.3mf", status: "ready")
      row.update!(source: "viewer")
      chosen = row.asset.blob.id

      Maker::GeneratePreviewJob.perform_now(row.id)

      row.reload
      assert_equal [ "viewer", "ready" ], [ row.source, row.status ]
      assert_equal chosen, row.asset.blob.id, "the render replaced the picture the maker chose"
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

    # THE JOB ASKS THE REGISTRY WHETHER IT CAN BUILD **THIS KIND**, NEVER THE BARE TOOLCHAIN. An
    # .svg's Measure payload is Nokogiri and arithmetic, so it must come back `ready` on a box with
    # no rasterizer; asking `renderer.available?` instead marks it `unsupported`. Nothing pinned that
    # once `available_for?` moved out of this job into Maker::Previews::Registry -- the gate could be
    # reverted with the suite green. Svg is the subject because it is the renderer whose two answers
    # DIFFER: Lbrn2's and Mage's `available?` are always true, so neither can tell the gates apart.
    test "an SVG's geometry payload renders with no rasterizer, because the job gates on the kind" do
      stage_version(node_id: "plate.svg", version_id: "vgeo", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "plate.svg", version_id: "vgeo", kind: "geometry")

      without_svg_rasterizer do
        Maker::GeneratePreviewJob.perform_now(preview.id, filename: "plate.svg")
      end

      preview.reload
      assert_equal "ready", preview.status, preview.error
      assert_equal "application/json", preview.asset.content_type
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
      # A LIVE NODE WHOSE BYTES ARE NOT THERE. On share that means a node with a storage_path
      # pointing at a file nobody wrote — the same condition the chunk fixture used to build with a
      # Version row referencing a chunk hash absent from the store. The node is staged deliberately:
      # without it, read rejects the node as not-live and this test would still go green while
      # never reaching the missing-bytes path it exists to cover.
      #
      # THE LIBRARY ROOT MUST EXIST FOR THIS TO BE THE TERMINAL ANSWER. Share#read maps ENOENT to
      # NotFound (terminal -> "failed") only when the root still looks mounted; when the whole root
      # is gone it answers the RETRYABLE FetchError instead, deliberately, so an unmounted NAS does
      # not burn every preview to a permanent failure (§14a).
      #
      # AN EMPTY ROOT READS AS UNMOUNTED, which is why the decoy below is load-bearing rather than
      # scenery. `use_fresh_share_library!` gives a real but EMPTY directory, and a library with no
      # files in it is exactly what a share that failed to mount looks like — so without a sibling
      # file this test got the retryable FetchError, the preview stayed "processing", and it
      # asserted the wrong arm. Measured, not reasoned: status came back "processing".
      @root.join("intact.svg").binwrite(@svg)
      stage_node(node_id: "broken.svg", version_id: "v3", storage_path: "broken.svg")
      preview = @user.maker_previews.create!(node_id: "broken.svg", version_id: "v3")

      Maker::GeneratePreviewJob.perform_now(preview.id, filename: "broken.svg")

      preview.reload
      assert_equal "failed", preview.status
      # Pins WHICH failure: without this, deleting the stage_node line above would leave the
      # test green on that error, silently losing the missing-chunk coverage.
      assert_match(/broken\.svg/, preview.error.to_s,
                   "the error must name the file whose bytes were missing -- without this, " \
                   "deleting the stage_node above leaves the test green on a DIFFERENT failure " \
                   "(node not live) and the missing-bytes coverage is silently lost")
      assert_not preview.asset.attached?
    end
  end
end
