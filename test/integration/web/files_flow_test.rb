require "test_helper"
require "support/mesh_fixture"
require "support/three_mf_fixture"

module Web
  # Exercises the server-rendered web UI end to end -- the file list, the detail page, blob
  # delivery, notes, delete and restore -- against a real library backend.
  #
  # THIS IS A WEB-LAYER SUITE, AND IT PINS A HERMETIC BACKEND ON PURPOSE. Until Arc D Part 2 it
  # pinned embedded `chunk` and seeded through Sync::Commit's two-phase presigned flow; with the
  # engine retired, neither exists. What these tests are actually ABOUT is the web layer -- that a
  # PNG blob is served inline, that a PDF page embeds the viewer, that notes render -- and none of
  # that is a claim about which backend holds the bytes. Backend behaviour is the adapter
  # contracts' job (adapter_contract.rb and friends), which run against all of them.
  #
  # A FRESH ROOT PER TEST, VIA `FileLayer.current =`, NOT ENV. Two reasons, both learned the hard
  # way here: the ambient LIBRARY_PATH is ONE tmpdir for the whole run while the database rolls
  # back per test, so leftovers on DISK outlive the rows that named them and the Share adapter's
  # clobber refusal (§14a) then rejects the second test to upload `pic.png` with "already exists";
  # and `pin_file_layer_backend` rebuilds from ENV, so it would additionally need LIBRARY_PATH,
  # which its teardown does not restore. Same idiom, same reasoning, as share_delivery_test.rb --
  # except that share_delivery_test.rb hand-rolls its root: `use_fresh_share_library!` now resets
  # FileLayer and removes its own directory in test_helper's teardown, so the pair below is
  # redundant rather than load-bearing.
  class FilesFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    # Real 3MF packages for the two manifest tests below — a slicer project and a plain CAD export.
    # `upload` puts real bytes through the port, and `Maker::ThreeMfManifest` really opens them.
    include ThreeMfFixture

    setup do
      @root = use_fresh_share_library!
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # Sign in via the real password auth. Creates a confirmed account if needed, then
    # logs in (sets the signed session cookie) — the web UI works behind real auth.
    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "web@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    # Delegates to test_helper's `port_upload` -- ONE definition, shared with the other suites
    # that need a file to exist. This was a local helper duplicated into lbrn_geometry_test.rb.
    def upload(name, bytes) = port_upload(name, bytes)

    test "requires login" do
      get files_path
      assert_redirected_to new_user_session_path
    end

    test "finalizing a chunk upload of a renderable file eagerly enqueues a thumbnail" do
      sign_in
      assert_enqueued_with(job: Maker::GeneratePreviewJob) do
        upload("bracket.stl", "solid bracket\nendsolid\n".b)
      end
    end

    # THE FOREVER-SPINNER GUARD. This asserted the OPPOSITE until 2026-08-26 — that a node with no
    # row is ABSENT from the payload — which described the code exactly and was the bug:
    # `thumbs_controller`'s `if (!entry) continue` leaves such a cell spinning AND in the poll set,
    # so it burns all 40 tries and then spins for as long as the page stays open. The failure had
    # been worked around three times at the callers (`_list`, `_grid`, `_hero_poster`) and was
    # still live in `projects/_attachment_group`. A terminal answer here fixes every caller at
    # once, including the two cover cards that hold no filename and cannot guard themselves.
    test "the thumbnails endpoint reports a ready thumbnail and a terminal status for one with no row" do
      user = sign_in
      # A renderable upload — the eager seam creates a pending thumbnail row for it (keyed by the
      # node's content_token). A non-renderable upload gets no row at all.
      with_thumb = upload("model.3mf", "zzz".b)
      without    = upload("notes.sldprt", "yyy".b)

      token = FileLayer.current.stat(user, node_id: with_thumb).content_token
      preview = user.maker_previews.find_by!(node_id: with_thumb, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")

      get thumbnails_files_path, params: { ids: [ with_thumb, without ].join(",") },
                                 headers: { "Accept" => "application/json" }
      assert_response :success
      data = JSON.parse(response.body)
      assert_equal "ready", data[with_thumb]["status"]
      assert data[with_thumb]["url"].present?, "a ready thumbnail must expose a url"
      assert_equal "unsupported", data[without]&.dig("status"),
                   "a node nothing can render must get a TERMINAL status, not be omitted — an " \
                   "omitted key is what the poller treats as 'keep waiting', forever"
      assert_nil data[without]["url"]
    end

    # THE OTHER HALF OF THE SAME RULE, AND THE ONE A CARELESS FIX BREAKS. "No row" has two causes
    # and only ONE of them is terminal: a name nothing renders is done forever, but a RENDERABLE
    # name whose row simply has not been created yet is still coming. Answering `unsupported` for
    # the second freezes a thumbnail that was genuinely on its way — trading a hung spinner for a
    # wrong badge, which is worse because it looks correct. `backfill: false` on this door is what
    # makes the second case reachable at all.
    test "a renderable node with no row yet is still omitted, so the client keeps polling" do
      user = sign_in
      stl = upload("pending.stl", "solid p\nendsolid\n".b)
      user.maker_previews.where(node_id: stl).delete_all

      get thumbnails_files_path, params: { ids: stl },
                                 headers: { "Accept" => "application/json" }
      assert_response :success
      data = JSON.parse(response.body)
      assert_not data.key?(stl),
                 "a renderable file whose row is merely absent must NOT be reported terminal"
    end

    # THE POLL IS THE ONE READ THAT MUST NOT WRITE, and it shares its implementation with the page
    # render that must. `Maker::Previews::ThumbnailMap.from_info` takes `backfill:` as a REQUIRED
    # argument precisely because these two callers disagree; this drives the real endpoint, because
    # a unit test of the map can only prove the flag works, never that this action passes it. The
    # cost of getting it wrong is a per-node write every 2 seconds, for up to 40 ticks, per open
    # page — for work the render that produced those spinners has already done.
    test "the thumbnails poll never enqueues, however long it is polled" do
      user = sign_in
      stl = upload("poller.stl", "solid p\nendsolid\n".b)
      user.maker_previews.where(node_id: stl).delete_all
      clear_enqueued_jobs

      assert_no_enqueued_jobs do
        3.times do
          get thumbnails_files_path, params: { ids: stl },
                                     headers: { "Accept" => "application/json" }
          assert_response :success
        end
      end
      assert_not user.maker_previews.exists?(node_id: stl),
                 "the poll created a preview row — it is a read, and #index is what heals"
    end

    test "viewing a folder backfills thumbnails for renderable files that lack one, not others" do
      user = sign_in
      stl   = upload("gear.stl", "solid gear\nendsolid\n".b)  # eager seam creates a pending row
      other = upload("design.sldprt", "xyz".b)               # not renderable -> no row

      # Simulate a library indexed BEFORE this feature: the renderable file has no preview row.
      user.maker_previews.where(node_id: stl).delete_all
      clear_enqueued_jobs

      assert_enqueued_with(job: Maker::GeneratePreviewJob) do
        get files_path
        assert_response :success
      end

      assert user.maker_previews.exists?(node_id: stl, kind: "thumbnail"),
             "the renderable file gets a backfilled thumbnail row on view"
      assert_not user.maker_previews.exists?(node_id: other),
                 "a non-renderable file is never enqueued and stays row-less (static icon, no spinner)"
    end

    test "the grid view renders files as thumbnail cards and remembers the choice" do
      user = sign_in
      node_id = upload("widget.3mf", "zzz".b)
      token = FileLayer.current.stat(user, node_id:).content_token
      preview = user.maker_previews.find_by!(node_id:, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")

      get files_path(view: "grid")
      assert_response :success
      assert_select ".files-grid"
      assert_select ".grid-card .grid-name", text: "widget.3mf"
      assert_select ".grid-card.file-cell img" # the ready thumbnail

      # The choice is remembered (cookie): a plain visit stays in grid.
      get files_path
      assert_select ".files-grid"

      # …and an explicit ?view=list switches back.
      get files_path(view: "list")
      assert_select "table.files"
      assert_select ".files-grid", count: 0
    end

    test "image, PDF, and text files are renderable, so they get grid thumbnail cells (not badges)" do
      user = sign_in
      png = upload("photo.png", "\x89PNG\r\n\x1a\nfake".b)
      pdf = upload("manual.pdf", "%PDF-1.4\nfake".b)
      txt = upload("notes.txt", "hello\nworld".b)
      [ png, pdf, txt ].each do |node_id|
        token = FileLayer.current.stat(user, node_id:).content_token
        p = user.maker_previews.find_by!(node_id:, version_id: token, kind: "thumbnail")
        p.update!(status: "ready")
        p.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")
      end

      get files_path(view: "grid")
      assert_response :success
      # each is renderable → a thumbnail cell with a ready <img>, not a plain format badge
      assert_select ".grid-card.file-cell img", minimum: 3
      assert_select ".generic-thumb", count: 0
    end

    test "the detail page shows a ready thumbnail for a CAD file instead of 'No inline preview'" do
      user = sign_in
      node_id = upload("widget.3mf", "zzz".b)
      token = FileLayer.current.stat(user, node_id:).content_token
      preview = user.maker_previews.find_by!(node_id:, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")

      get file_path(node_id)
      assert_response :success
      assert_select "img.preview-image"
      assert_no_match(/No inline preview/, response.body)
    end

    # ---- Fix 9: sniffable user content is served as a download, never inline ---

    test "an SVG blob is served as an attachment (no stored XSS on the app origin)" do
      sign_in
      node_id = upload("evil.svg", "<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>".b)

      get blob_file_path(node_id)
      assert_response :success
      assert_match(/attachment/, response.headers["Content-Disposition"], "SVG must not render inline")
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    end

    test "an HTML blob is served as an attachment" do
      sign_in
      node_id = upload("page.html", "<html><body><script>alert(1)</script></body></html>".b)

      get blob_file_path(node_id)
      assert_response :success
      assert_match(/attachment/, response.headers["Content-Disposition"])
    end

    test "a PNG blob is still served inline (safe raster image)" do
      sign_in
      node_id = upload("pic.png", "\x89PNG\r\n\x1a\nfake".b)

      get blob_file_path(node_id)
      assert_response :success
      assert_match(/inline/, response.headers["Content-Disposition"], "raster images stay inline")
    end

    test "a PDF blob is served inline so the browser's own viewer renders it" do
      sign_in
      node_id = upload("manual.pdf", "%PDF-1.4\nfake".b)

      get blob_file_path(node_id)
      assert_response :success
      assert_match(/inline/, response.headers["Content-Disposition"], "PDF renders inline in the viewer")
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    end

    test "the PDF detail page embeds the PDF viewer instead of 'No inline preview'" do
      sign_in
      node_id = upload("manual.pdf", "%PDF-1.4\nfake".b)

      get file_path(node_id)
      assert_response :success
      assert_select "iframe.preview-pdf"
      assert_no_match(/No inline preview/, response.body)
    end

    # ---- Interactive 3D viewer — client-side, supersedes the static thumbnail ----

    test "an STL detail page renders the 3D viewer button-gated (lazy), not auto-loading" do
      sign_in
      node_id = upload("bracket.stl", "solid bracket\nendsolid\n".b)

      get file_path(node_id)
      assert_response :success
      assert_select ".model-viewer[data-controller=?]", "modelviewer"
      # THE NAMED BLOB ROUTE, AND THE FILENAME IN IT IS THE POINT. Online3DViewer picks an importer
      # from the URL'S OWN trailing extension, so the extensionless `blob_file_path` this used until
      # 2026-09-06 reaches no importer at all — the identical trap KiCanvas fell into, and the
      # reason that route exists (config/routes.rb).
      assert_select ".model-viewer[data-modelviewer-url-value=?]",
                    named_blob_file_path(node_id, filename: "bracket.stl")
      assert_select ".model-viewer[data-modelviewer-format-value=?]", "stl"
      # Button-gated: the viewer waits for a click instead of fetching bytes on load.
      assert_select ".model-viewer[data-modelviewer-lazy-value=?]", "true"
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
      # The reset/fullscreen/show-image controls are wired.
      assert_select "[data-action~=?]", "modelviewer#reset"
      assert_select "[data-action~=?]", "modelviewer#fullscreen"
      assert_select "[data-action~=?]", "modelviewer#showPoster"
      # NOT A 3MF, SO THE MANIFEST ATTRIBUTES ARE THE NO-OP PAIR. Empty and 1 mean "apply nothing,
      # scale by nothing" — asserted here rather than left implicit, because the controller reads
      # both on EVERY format and a missing attribute would make `unitFactorValue` 0 for STL too.
      assert_select ".model-viewer[data-modelviewer-colors-value=?]", "[]"
      assert_select ".model-viewer[data-modelviewer-unit-factor-value=?]", "1.0"
    end

    # THE SLICER'S COLOURS AND THE DECLARED UNIT REACH THE PAGE AS DATA, which is the whole server
    # half of the feature: three's 3MFLoader can read neither (the colours are Bambu metadata, the
    # `unit` attribute it simply ignores), so `Maker::ThreeMfManifest` reads them here and the
    # browser applies them by mesh index. The unit test owns what the manifest SAYS; this owns that
    # the page carries it.
    test "a Bambu 3MF page carries its filament colours and unit factor as data" do
      sign_in
      node_id = upload("plate.3mf", bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 } ],
                                              filaments: %w[#161616 #F98C36 #FFFFFF]))

      get file_path(node_id)
      assert_response :success
      assert_select ".model-viewer[data-modelviewer-colors-value=?]", '["#161616","#F98C36"]'
      assert_select ".model-viewer[data-modelviewer-unit-factor-value=?]", "1.0"
    end

    # THE ONSHAPE CASE, WHICH IS A MEASUREMENT BUG RATHER THAN A COLOUR ONE: a part declaring
    # `unit="meter"` reads 1000x short in the dims line without this number.
    test "a 3MF declaring metres carries the factor that makes its dimensions right" do
      sign_in
      node_id = upload("part.3mf", plain_3mf(unit: "meter"))

      get file_path(node_id)
      assert_response :success
      assert_select ".model-viewer[data-modelviewer-unit-factor-value=?]", "1000.0"
      assert_select ".model-viewer[data-modelviewer-colors-value=?]", "[null]"
    end

    # ONE PER IMPORTER FAMILY, not one per extension: Online3DViewer's own mesh readers (3mf, obj,
    # ply, off), its glTF reader (gltf, glb), the three.js-backed ones (dae, wrl, 3ds, fbx, amf),
    # rhino3dm (3dm) and the OpenCascade wasm (step, iges, brep, fcstd). A format missing from
    # Maker::FileAttachment::VIEWABLE_3D_EXTS renders "No inline preview for this file type."
    test "every viewable 3D format reaches the viewer with its own format value" do
      sign_in
      { "part.3mf" => "3mf", "widget.obj" => "obj", "scan.ply" => "ply", "mesh.off" => "off",
        "scene.gltf" => "gltf", "scene.glb" => "glb", "rig.dae" => "dae", "world.wrl" => "wrl",
        "old.3ds" => "3ds", "char.fbx" => "fbx", "surf.3dm" => "3dm", "print.amf" => "amf",
        "cad.iges" => "iges", "cad.igs" => "igs", "solid.brep" => "brep",
        "body.fcstd" => "fcstd" }.each do |name, fmt|
        node_id = upload(name, "data".b)
        get file_path(node_id)
        assert_response :success
        assert_select ".model-viewer[data-modelviewer-format-value=?]", fmt
        assert_select ".model-viewer[data-modelviewer-url-value=?]",
                      named_blob_file_path(node_id, filename: name)
      end
    end

    # THE THUMBNAIL BECAME THE POSTER, IT DID NOT GO AWAY — and a STEP file is where that reads
    # most differently from before. This page was a bare `img.preview-image` with no viewer at all
    # until 2026-09-06; the server-rendered PNG is now the resting state INSIDE the viewer's
    # fallback, which is also where it lands if the OpenCascade importer cannot boot.
    test "a STEP file's server thumbnail becomes the 3D viewer's poster" do
      user = sign_in
      node_id = upload("cad.step", "ISO-10303-21;".b)
      token = FileLayer.current.stat(user, node_id:).content_token
      preview = user.maker_previews.find_by!(node_id:, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")

      get file_path(node_id)
      assert_response :success
      assert_select ".model-viewer[data-modelviewer-format-value=?]", "step"
      assert_select ".model-viewer-fallback img.preview-image"
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
    end

    # THE OTHER SIDE OF THE VOCABULARY, so the widening stays a decision rather than a drift. A
    # `.f3d` is role `model`-adjacent (`cad_source`) and there is no importer for it in any engine
    # we ship — the page must keep saying so instead of opening a viewer that can only fail.
    test "a CAD source file with no importer gets no 3D viewer" do
      sign_in
      node_id = upload("part.f3d", "binary".b)
      get file_path(node_id)
      assert_response :success
      assert_select ".model-viewer", count: 0
      assert_match(/No inline preview/, response.body)
    end

    test "a LightBurn file's detail page shows the laser-settings panel beside the preview" do
      user = sign_in
      bytes = File.binread(Rails.root.join("test/fixtures/files/laser-settings.lbrn2"))
      node_id = upload("cut.lbrn2", bytes)
      # Give the thumbnail preview parsed metadata directly (this test targets the VIEW, not the job).
      # find_or_create_by!: the upload's finalize may already have created the pending thumbnail
      # preview row (Previews::Enqueue), so a bare create! would hit the (user,node,version,kind)
      # uniqueness index.
      token = FileLayer.current.stat(user, node_id:).content_token
      preview = Maker::Preview.find_or_create_by!(user:, node_id:, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready", metadata: Maker::Previews::LbrnMetadata.parse(bytes))

      get file_path(node_id)
      assert_response :success
      assert_select ".preview-row.has-settings"
      assert_select ".lbrn-settings"
      assert_select ".lbrn-settings table tbody tr", 2          # two used layers
      assert_select ".lbrn-settings", text: /C00/
      assert_select ".lbrn-settings", text: /Fill/               # Scan -> Fill
      assert_select ".lbrn-settings", text: /Ortur LM2/
    end

    test "a non-LightBurn thumbnail file shows no laser-settings panel" do
      user = sign_in
      node_id = upload("cad.step", "ISO-10303-21;".b)
      token = FileLayer.current.stat(user, node_id:).content_token
      Maker::Preview.find_or_create_by!(user:, node_id:, version_id: token, kind: "thumbnail")
                    .update!(status: "ready")   # no metadata -> no panel

      get file_path(node_id)
      assert_response :success
      assert_select ".lbrn-settings", count: 0
      assert_select ".has-settings", count: 0
    end

    test "a malicious layer colour is not injected into the swatch style" do
      user = sign_in
      node_id = upload("evil.lbrn2", "x".b)
      token = FileLayer.current.stat(user, node_id:).content_token
      evil = { "layers" => [ { "index" => "0", "name" => "C00",
                               "color" => "#fff; background-image:url(https://evil.example/x.png)" } ],
               "shape_count" => 1 }
      Maker::Preview.find_or_create_by!(user:, node_id:, version_id: token, kind: "thumbnail")
                    .update!(status: "ready", metadata: evil)

      get file_path(node_id)
      assert_response :success
      assert_select ".lbrn-swatch", { count: 0 }, "an unsafe colour string renders no swatch"
      assert_no_match(/evil\.example/, response.body)
    end

    test "placeholder login signs in and lists files" do
      sign_in
      get files_path
      assert_response :success
      assert_select "h1", "Files"
    end

    test "upload -> list -> download byte-for-byte" do
      sign_in
      bytes = "hello tinkerex \x00\x01\x02 binary".b
      node_id = upload("notes.txt", bytes)

      # Appears in the list (a non-renderable .txt renders as a plain name link).
      get files_path
      assert_response :success
      assert_select "a", text: "notes.txt"

      # THE VERSION AND CHUNK ROWS ARE NOT ASSERTED HERE ANY MORE, AND THAT IS NOT A WEAKENING OF
      # THIS TEST -- it is the assertion moving to the layer that owns it. Those rows are the sync
      # engine's, which since Arc D Part 2 lives in another process entirely; what this test is
      # about is the WEB round trip (upload -> the file appears in the list -> the bytes come back
      # byte-for-byte), and that is asserted in full above and below. Whether a commit produced a
      # version and a content-addressed chunk is the sync server's own suite's question.
      user = User.find_by(email: "web@example.com")
      assert_equal 1, user.nodes.present.where(kind: "file").count

      # Download returns the exact bytes.
      get blob_file_path(node_id, download: 1)
      assert_response :success
      assert_equal bytes, response.body.b
    end

    test "image preview renders an <img> to the blob endpoint" do
      sign_in
      png = "\x89PNG\r\n\x1a\nfake-image-bytes".b
      node_id = upload("pic.png", png)

      get file_path(node_id)
      assert_response :success
      assert_select "img.preview-image"
    end

    test "text preview page renders the text container" do
      sign_in
      node_id = upload("readme.md", "# Hello\nworld".b)
      get file_path(node_id)
      assert_response :success
      assert_select "pre.preview-text"
    end

    # THE DRIVEN HALF of test/controllers/files_controller_preview_kind_test.rb, which asks
    # preview_kind directly. That a source file resolves to :text says nothing about whether the
    # PAGE reaches the text container — the branch is in the view, and this is the one backend
    # suite that renders it.
    test "a source file's detail page renders the text container too" do
      sign_in
      node_id = upload("firmware.cpp", "#include <Arduino.h>\nvoid setup() {}\n".b)
      get file_path(node_id)
      assert_response :success
      assert_select "pre.preview-text"
    end

    # THE RENDERED ATTRIBUTES, NOT THE RUBY THAT PRODUCES THEM (§14d). A data-controller naming
    # nothing is a SILENT no-op — Stimulus neither throws nor warns on an identifier it cannot
    # resolve — and a values mismatch is equally silent, so what reaches the page is the only
    # thing worth asserting. THE FIXTURE'S NAME IS DELIBERATELY UPPER-CASE: the view's ext value
    # is `File.extname(name).downcase.delete(".")`, three steps, and a file already called
    # `x.cpp` would pass with two of them deleted.
    test "a source file's page wires codeview with a normalised extension" do
      sign_in
      node_id = upload("Firmware.CPP", "#include <Arduino.h>\n".b)
      get file_path(node_id)

      assert_response :success
      assert_select "[data-controller=codeview]", 1
      assert_select "[data-codeview-ext-value=cpp]", 1
      assert_select "[data-codeview-url-value=?]", blob_file_path(node_id), count: 1
      # INSIDE the controller's own element, not merely somewhere on the page. Stimulus resolves a
      # target only within the subtree of the controller that declares it, so a fallback that
      # drifted outside would be a target `this.fallbackTarget` can never find — and the graceful
      # degradation this whole branch is built around would raise instead.
      assert_select "[data-controller=codeview] pre.preview-text[data-codeview-target=fallback]", 1
    end

    # THE DEFAULT IS NO LANGUAGE, NOT A GUESS, and this is the half of that rule the server owns:
    # `txt` has no entry in app/javascript/lib/codemirror_languages.js and must not get one. What
    # must still be true is that the value ARRIVES — an empty ext value looks identical on the
    # page and would mean the controller could never highlight anything at all.
    test "an extension with no language still reaches codeview, carrying its own ext" do
      sign_in
      node_id = upload("notes.txt", "plain words\n".b)
      get file_path(node_id)

      assert_response :success
      assert_select "[data-codeview-ext-value=txt]", 1
    end

    test "the file detail page shows a notes section and renders note bodies" do
      user = sign_in
      node_id = upload("part.stl", "solid".b)
      # Real HTML, not markdown syntax: notes are Action Text now, which renders whatever markup
      # a body actually contains rather than interpreting markdown -- a Lexxy-authored note gets
      # its <strong> from the user clicking Bold, not from typing asterisks. (Verified: assigning
      # "**important** note" directly renders as the literal six-character string, no <strong>.)
      user.maker_notes.create!(node_id:, body: "<p><strong>important</strong> note</p>")
      get file_path(node_id)
      assert_response :success
      assert_select ".notes-panel .note .note-body strong", text: "important"
      # Was `textarea` — Lexxy's rich_text_area renders one <lexxy-editor> custom element
      # carrying the form field's name; there is no separate <textarea> anywhere in the form.
      assert_select ".note-form lexxy-editor"
    end

    test "a file with notes shows a note-count badge in grid and list" do
      user = sign_in
      node_id = upload("part.stl", "solid".b)
      user.maker_notes.create!(node_id:, body: "one")
      user.maker_notes.create!(node_id:, body: "two")

      get files_path(view: "grid")
      assert_select ".note-badge", text: /2/
      get files_path(view: "list")
      assert_select ".note-badge", text: /2/
    end

    test "a file with no notes shows no badge" do
      sign_in
      upload("plain.stl", "solid".b)
      get files_path(view: "grid")
      assert_select ".note-badge", count: 0
    end

    # The right-click menu is JS (not exercised by integration tests); this pins the wiring the
    # filemenu controller reads — the container controller + each file cell's note-url.
    test "the files browser wires the right-click note menu on file cells" do
      sign_in
      node_id = upload("part.stl", "solid".b)

      get files_path(view: "list")
      assert_select "table.files[data-controller~=?]", "filemenu"
      assert_select "[data-note-url=?]", file_notes_path(node_id)

      get files_path(view: "grid")
      assert_select ".files-grid[data-controller~=?]", "filemenu"
      assert_select "[data-note-url=?]", file_notes_path(node_id)
    end

    test "unknown type falls back to a download link" do
      sign_in
      # A genuinely non-renderable type (no Registry renderer, not image/pdf/text) -> :other ->
      # the download fallback. (Was .stl, which is now the interactive :model3d viewer.)
      node_id = upload("model.sldprt", "binary cad".b)
      get file_path(node_id)
      assert_response :success
      assert_select ".preview-fallback"
    end

    # CHUNK MODE'S DELETE BELONGS TO THE SYNC ENGINE AND MUST STAY THERE. #destroy branches on
    # port_writable, and the share/s3 half calls FileLayer#delete -- but here the bytes belong to
    # the sync engine, the tombstone IS the whole delete, and changing what Sync::* does is the
    # tripwire (spec §10). So the assertions below are about the MECHANISM, not just the outcome:
    # a tombstone alone is what a port delete would also produce.
    #
    # (The door is Sync::SubtreeDelete, and on this fixture -- a childless file -- it collects
    # exactly one node and mints exactly the single entry asserted below. An earlier version of
    # this comment named Sync::Mutation, which the action did call and which orphans a directory's
    # children; the test could not tell, because a file has none. See the directory test below.)
    test "delete tombstones the node and removes it from the list" do
      sign_in
      node_id = upload("trash.txt", "bye".b)
      before = User.find_by(email: "web@example.com").head_seq
      delete file_path(node_id)
      assert_redirected_to files_path

      user = User.find_by(email: "web@example.com")
      assert user.nodes.find_by(node_id:).deleted?, "node should be tombstoned"
      assert_equal 0, user.nodes.present.count
      # The keep-versions rule (§5) is the sync engine's and is asserted in its own repo; on a
      # share-backed library there is no version row to retain, which is §14a's recorded departure
      # rather than a gap here.

      # THE CHANGELOG ASSERTION LEFT WITH THE ENGINE. It existed to distinguish "the sync engine
      # deleted it" from "the port did" -- a distinction that no longer exists here, because since
      # Arc D Part 2 there is only ONE door: the port. On a share-backed library there is no
      # changelog at all (§14a), and on chunk_remote the entry is appended by the sync SERVER, in
      # another process, where its own suite asserts it. What this test still proves, and all it
      # ever needed to prove about the web layer, is above: the node is tombstoned and it is gone
      # from the list.
    end

    # THE GATE IS NOT AUTH AND NOT A MISSING ROUTE, proven: the same POST, unauthenticated,
    # redirects to login. If POST /files were unrouted this would 404 instead, and the 501 above
    # would have proved nothing.
    test "the direct upload route exists and is behind auth" do
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("bytes"), "application/octet-stream",
                                           original_filename: "direct.stl")
      }
      assert_redirected_to new_user_session_path
    end

    test "isolation: a user cannot see or fetch another user's file" do
      sign_in("alice@example.com")
      alice_node = upload("secret.txt", "alice only".b)

      # Sign in as bob.
      delete destroy_user_session_path
      sign_in("bob@example.com")

      # Bob's library has no such node -> not found (never alice's bytes).
      get blob_file_path(alice_node)
      assert_redirected_to files_path
      assert_equal 0, User.find_by(email: "bob@example.com").nodes.present.count

      get file_path(alice_node)
      assert_redirected_to files_path
    end
  end
end
