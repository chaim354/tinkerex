require "test_helper"

module Web
  # Exercises the server-rendered web UI end to end through the SAME presign + Sync::Commit
  # machinery the desktop client uses, with the memory chunk store backed by the dev blob
  # endpoint (so bytes actually round-trip without S3, while never going through v1/Rails).
  class FilesFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    # For the finalize_upload broadcast test below -- same idiom chunk_test.rb, library_channel_test.rb
    # and project_intake_test.rb already use for assert_broadcast_on/assert_no_broadcasts.
    include ActionCable::TestHelper
    # This suite's FIXTURES are chunk-shaped -- it uploads through Sync::Commit's two-phase flow
    # and asserts ManifestChunk rows -- so it is a chunk test and now has to SAY so. It did not
    # need to before Phase 4 Task 3: #blob reached for Sync::Storage::ChunkStore.current directly, which
    # ignores LIBRARY_BACKEND, so it passed on the share/s3 legs by being blind to the backend
    # rather than by being right. Routing #blob through FileLayer.current is what made the
    # dependency real, and the share leg reported it immediately (ActionController::MissingFile --
    # the Share adapter looking for these chunks' bytes on a disk that has none).
    #
    # That is the honest signal test_helper documents at pin_file_layer_backend, not a regression:
    # nothing about the assertions below changed, only the declaration of which deployment they
    # are about.
    setup do
      pin_file_layer_backend("chunk")
      Sync::Storage::ChunkStore.reset!
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

    # Mirror the browser uploader: hash -> begin_upload -> PUT bytes -> finalize_upload.
    def upload(name, bytes)
      hash = Digest::SHA256.hexdigest(bytes)
      manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
      post begin_upload_files_path, params: { name:, size: bytes.bytesize, manifest: }, as: :json
      assert_response :success
      begun = JSON.parse(response.body)

      (begun["put_urls"] || {}).each_value do |url|
        put url, params: bytes, headers: { "CONTENT_TYPE" => "application/octet-stream" }
        assert_response :ok
      end

      post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
      assert_response :success
      begun["node_id"]
    end

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

    test "the thumbnails endpoint reports a ready thumbnail and omits nodes without one" do
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
      assert_not data.key?(without), "a node with no thumbnail row is absent from the payload"
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

    # ---- Interactive 3D viewer (STL/3MF/OBJ) — client-side, supersedes the static thumbnail ----

    test "an STL detail page renders the 3D viewer button-gated (lazy), not auto-loading" do
      sign_in
      node_id = upload("bracket.stl", "solid bracket\nendsolid\n".b)

      get file_path(node_id)
      assert_response :success
      assert_select ".model-viewer[data-controller=?]", "modelviewer"
      assert_select ".model-viewer[data-modelviewer-url-value=?]", blob_file_path(node_id)
      assert_select ".model-viewer[data-modelviewer-format-value=?]", "stl"
      # Button-gated: the viewer waits for a click instead of fetching bytes on load.
      assert_select ".model-viewer[data-modelviewer-lazy-value=?]", "true"
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
      # The reset/fullscreen/show-image controls are wired.
      assert_select "[data-action~=?]", "modelviewer#reset"
      assert_select "[data-action~=?]", "modelviewer#fullscreen"
      assert_select "[data-action~=?]", "modelviewer#showPoster"
    end

    test "3MF and OBJ also render the 3D viewer, with the right format value" do
      sign_in
      { "part.3mf" => "3mf", "widget.obj" => "obj" }.each do |name, fmt|
        node_id = upload(name, "data".b)
        get file_path(node_id)
        assert_response :success
        assert_select ".model-viewer[data-modelviewer-format-value=?]", fmt
      end
    end

    test "a STEP file keeps the static thumbnail preview (not the 3D viewer)" do
      user = sign_in
      node_id = upload("cad.step", "ISO-10303-21;".b)
      token = FileLayer.current.stat(user, node_id:).content_token
      preview = user.maker_previews.find_by!(node_id:, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")

      get file_path(node_id)
      assert_response :success
      assert_select "img.preview-image"
      assert_select ".model-viewer", count: 0
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

      # A version + content-addressed chunk were recorded through Sync::Commit.
      user = User.find_by(email: "web@example.com")
      assert_equal 1, user.nodes.present.where(kind: "file").count
      assert user.versions.where(node_id:).exists?
      assert user.chunks.where(chunk_hash: Digest::SHA256.hexdigest(bytes)).exists?

      # Download returns the exact bytes.
      get blob_file_path(node_id, download: 1)
      assert_response :success
      assert_equal bytes, response.body.b
    end

    test "dedup: re-uploading identical content uploads no new chunk" do
      sign_in
      bytes = "duplicate me".b
      upload("a.txt", bytes)

      # Second begin for the same content should report nothing missing (chunk exists).
      hash = Digest::SHA256.hexdigest(bytes)
      manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
      post begin_upload_files_path, params: { name: "b.txt", size: bytes.bytesize, manifest: }, as: :json
      assert_response :success
      assert_empty JSON.parse(response.body)["put_urls"]
    end

    # ---- begin_upload / finalize_upload: the two port-verb error paths (Task 8) -------------
    #
    # Neither of these had ANY test coverage at this layer before Task 8 -- only the underlying
    # Sync::Commit.begin/.finalize had unit tests, and V1::CommitsController's OWN chunks_missing
    # response was covered, but never this controller's. Both responses moved from a per-action
    # `rescue Sync::Commit::*` to FileLayer::Chunk re-raising through the port's own vocabulary
    # (see Chunk#begin_upload/#finalize_upload's own comments); these drive the REAL HTTP request
    # to prove the response BODY, not just the exception class, survived the move unchanged.
    test "begin_upload answers 422 for a manifest with a malformed chunk hash" do
      sign_in
      assert_no_difference -> { Sync::PendingCommit.count } do
        post begin_upload_files_path,
             params: { name: "bad.stl", size: 5,
                       manifest: [ { hash: "not-a-real-hash", offset: 0, length: 5 } ] },
             as: :json
      end
      assert_response :unprocessable_entity
      assert_match(/invalid chunk hash/, JSON.parse(response.body)["error"])
    end

    test "finalize_upload answers 422 chunks_missing when the bytes were never PUT" do
      sign_in
      hash = SecureRandom.hex(32)
      manifest = [ { hash:, offset: 0, length: 5 } ]
      post begin_upload_files_path, params: { name: "ghost.stl", size: 5, manifest: }, as: :json
      assert_response :success
      begun = JSON.parse(response.body)
      refute_empty begun["put_urls"], "the store must not already know this hash"

      # Deliberately no PUT of the bytes here.
      post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert_equal "chunks_missing", body["error"]
      assert_equal [ hash ], body["missing"]
      assert_not User.find_by!(email: "web@example.com").nodes.exists?(node_id: begun["node_id"]),
                 "a rejected finalize must not create the node"
    end

    # Drives the REAL request end to end -- FilesController#finalize_upload now reads `result.seq`
    # off FileLayer::UploadFinalized and calls Sync::LibraryChannel.broadcast_change itself (Task 8: the
    # port method does NOT self-broadcast, unlike mkdir/move/delete/undelete; see
    # Chunk#finalize_upload's own comment for why). A wrong field read there (or a dropped call)
    # would still return 200 -- only listening on the real stream can catch it, which is why this
    # is asserted here rather than only at the adapter level.
    test "finalize_upload broadcasts the new head_seq over the real request" do
      user = sign_in
      before = user.reload.head_seq
      bytes = "bcast via http".b
      hash = Digest::SHA256.hexdigest(bytes)
      manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
      post begin_upload_files_path, params: { name: "bcast.stl", size: bytes.bytesize, manifest: }, as: :json
      assert_response :success
      begun = JSON.parse(response.body)
      begun["put_urls"].each_value do |url|
        put url, params: bytes, headers: { "CONTENT_TYPE" => "application/octet-stream" }
        assert_response :ok
      end

      assert_broadcast_on(Sync::LibraryChannel.broadcasting_for(user), head_seq: before + 1) do
        post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
      end
      assert_response :success
    end

    # ---- begin_upload: the name is a name ------------------------------------------------
    #
    # THE CHUNK WEB UPLOAD DOOR HAD NO NAME CHECK OF ANY KIND — not the reserved-namespace one, and
    # not even the traversal one §14c records as closed at the addon door. `#begin_upload` took
    # `params.require(:name)` and handed it straight to Sync::Commit.begin, which validates the
    # MANIFEST exhaustively and the name not at all; Node validates `name` for presence only. So on
    # the product's MAIN deployment this door was strictly weaker than the addon door beside it.
    #
    # PROBED THROUGH THE REAL TWO-PHASE FLOW, not reasoned about: begin=200, finalize=200, and a
    # live node named "../../escape.txt" — in the changelog and bound for every device's real
    # mount. That is the same defect the addon door's own test calls "the main deployment created a
    # live node called '../../escape.txt'", still open one controller over.
    #
    # THE GUARD IS AT `begin`, NOT `finalize`, because that is where the name enters: finalize is
    # handed a commit_id and never sees a name at all. A check there would be validating a decision
    # already recorded.
    #
    # Whole suite pins chunk (see setup) — and chunk is exactly the exposed backend here, since
    # begin_upload is `syncable`-gated and does not exist on share/s3 at all. There is no other leg
    # for this door, which is why nothing cross-backend could have caught it.
    #
    # Mutation-checked (§15): dropping either guard from #begin_upload turns its own rows red — the
    # traversal rows for valid_leaf_name?, the reserved rows for Library::ReservedNames.
    test "begin_upload refuses a name that is not a storable leaf" do
      sign_in
      [ "../../escape.txt", "a/b.txt", "a\\b.txt", "..", ".", "nul\0byte", "x" * 300 ].each do |bad|
        assert_no_difference -> { Sync::PendingCommit.count }, "#{bad.inspect} began a commit" do
          post begin_upload_files_path,
               params: { name: bad, size: 1, manifest: [] }, as: :json
        end
        assert_response :unprocessable_entity, "#{bad.inspect} was not refused"
      end
    end

    test "begin_upload refuses a name the library scan will never index" do
      sign_in
      %w[.DS_Store ._resource __MACOSX .Trashes .Spotlight-V100 .trash .maker-tmp-x].each do |bad|
        assert_no_difference -> { Sync::PendingCommit.count }, "#{bad.inspect} began a commit" do
          post begin_upload_files_path,
               params: { name: bad, size: 1, manifest: [] }, as: :json
        end
        assert_response :unprocessable_entity, "#{bad.inspect} was not refused"
      end
    end

    # The positive control, driven through the WHOLE two-phase flow rather than begin alone: a
    # near-miss name must still upload end to end. Without this, a guard widened to a prefix match
    # would pass every row above and quietly refuse real files.
    test "begin_upload accepts a name that merely starts with a reserved prefix" do
      user = sign_in
      node_id = upload(".trashcan.svg", "<svg/>".b)
      assert user.nodes.present.exists?(node_id:, name: ".trashcan.svg")
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
      # Version is retained (keep-versions rule).
      assert user.versions.where(node_id:).exists?

      # The sync engine, and nothing else here, appends a changelog entry and advances head_seq --
      # so this is what distinguishes "the sync engine deleted it" from "the port did". A
      # syncing device learns about this delete ONLY through this entry.
      entry = user.changelog_entries.where(node_id:).order(:seq).last
      assert_equal "delete", entry.op
      assert_operator user.head_seq, :>, before
    end

    # DELETING A DIRECTORY MUST TAKE ITS CHILDREN, and before this it did not: #destroy called
    # Sync::Mutation.apply(op: "delete"), which tombstones ONLY the node it is handed. The
    # directory went, the child stayed live pointing at a deleted parent, and /v1/tree -- which
    # serves `nodes.present` -- kept serving it, while a changelog-following device dropped the
    # whole subtree client-side. The two views of one library disagreed, permanently, from a
    # button the UI renders for every directory.
    #
    # The child's own `delete` entry is asserted rather than just its tombstone: a device converges
    # via the changelog, so a cascade that skipped the entry would leave the same divergence with a
    # tidier database.
    test "deleting a directory tombstones its children too, and tells the changelog about each" do
      sign_in
      user = User.find_by(email: "web@example.com")
      user.nodes.create!(node_id: "dir-1", name: "cad", kind: "dir")
      user.nodes.create!(node_id: "kid-1", name: "a.stl", kind: "file", parent_node_id: "dir-1")
      user.nodes.create!(node_id: "kid-2", name: "b.stl", kind: "file", parent_node_id: "dir-1")

      delete file_path("dir-1")
      assert_redirected_to files_path

      assert_equal 0, user.nodes.present.count,
                   "a live child under a deleted parent is what /v1/tree would serve"
      %w[dir-1 kid-1 kid-2].each do |id|
        assert user.nodes.find_by(node_id: id).deleted?, "#{id} should be tombstoned"
        assert user.changelog_entries.exists?(node_id: id, op: "delete"),
               "#{id} needs its own changelog entry -- it is how a device learns"
      end
    end

    # THE OTHER HALF OF CAPABILITY GATING, and the half a plan forgets. A gate that hides a
    # feature in share mode is half-right; a gate that hides it in the product's MAIN deployment
    # is a straightforward bug, and it is the easy one to ship -- `port_writable` reads like
    # "accepts uploads", which chunk mode very much does (that is what Sync::Commit IS).
    #
    # So this is the counterpart to share_delivery_test.rb's "does not offer a version": the same
    # two surfaces, asserted present rather than absent. Without it, a gate that fired everywhere
    # would leave both suites green while the product lost its upload button and its versions.
    test "chunk mode keeps version history and the upload control" do
      sign_in
      node_id = upload("v.stl", "bytes")

      get file_path(node_id)
      assert_response :success
      assert_match(/Current version/i, response.body,
                   "chunk is the versioned backend -- the gate must not fire here")
      assert_match(/5 Bytes/i, response.body, "size must survive the move from Version to the port")

      get files_path
      assert_match(/upload/i, response.body,
                   "chunk mode uploads via the two-phase flow -- port_writable: false does NOT " \
                   "mean 'no uploads', and reading it that way hides this button in production")
      # WHICH upload control, not just that one exists. Both branches of the view say "Upload a
      # file", so /upload/i alone stays green with the branch INVERTED -- chunk mode would render
      # the direct form, POST /files, and take a 501. Verified by mutation: only the share side
      # caught it. This is the chunk-side half.
      assert_match(/data-controller="uploader"/, response.body,
                   "chunk mode must drive the two-phase flow, not POST the bytes to the port")
    end

    # The other direction of the upload branch. Chunk mode CAN accept uploads -- it does so all
    # day via the two-phase presigned flow -- it just cannot take the bytes through Rails (§15).
    # So the direct endpoint is an honest 501, and it must NAME the flow that does work: a bare
    # 501 here would read as "uploads are off", which is exactly wrong.
    test "the direct upload answers 501 in chunk mode, naming the two-phase flow" do
      sign_in
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("bytes"), "application/octet-stream",
                                           original_filename: "direct.stl")
      }
      assert_response :not_implemented
      assert_match(/port_writable_unavailable/, response.body,
                   "the 501 must be the capability gate, not a routing or auth accident")
      assert_match(/begin_upload/, response.body,
                   "a refusal must name the path the caller SHOULD use -- as Chunk#write does")
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
