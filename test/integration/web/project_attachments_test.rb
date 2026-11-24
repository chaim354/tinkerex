require "test_helper"
require_relative "../../support/fake_addon_source"

module Web
  class ProjectAttachmentsTest < ActionDispatch::IntegrationTest
    # A page render ENQUEUES (Maker::Previews::ThumbnailMap backfills), and one case below counts
    # those jobs. Recorded, never run — the :test adapter is what `assert_enqueued_jobs` reads.
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(user, password: PASSWORD)
    end

    # Seed a library node + attach it to a project via the model (attach UI is Task 6). THE NODE
    # SITS AT THE ROOT OF THE PROJECT'S FOLDER (its Loose files), minting the folder's rows on first
    # use: since 2026-11-19 an attachment to a file OUTSIDE the folder is not drawn on the page at
    # all (the "Linked from elsewhere" group left), and the tests below need an attached, live file
    # on the page.
    def attach_node(user, project, name:, node_id:, role: "model")
      folder = project.folder_node_id || project_folder_rows!(user, project).node_id
      user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: folder)
      project.file_attachments.create!(user:, node_id:, role:)
    end

    # A node placed INSIDE a folder — the project's own root, or a subfolder created separately
    # with kind: "dir" and passed as `parent`. This is what Maker::ProjectFolderListing walks, so a
    # test about the tree, Backups, or a repository needs its fixtures here rather than at
    # attach_node's library root. Ensures the project's folder once; the ensure is idempotent
    # (Maker::Project#ensure_library_folder!), so calling it once per fixture in a test with several
    # is harmless.
    def folder_file!(user, project, name:, node_id:, parent: nil)
      folder = project.ensure_library_folder!(user)
      user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent || folder.node_id)
    end

    # Like attach_node, but the node lives inside the project's folder rather than at the library
    # root, AND an attachment row is created for it — the shape the pre-folder grouping tests
    # already assumed (an attached file, live, counted once). A folder row needs no attachment at
    # all to be listed (folder_file! above covers that), but several existing tests are about the
    # attachment relation surviving the folder split, not just the folder listing on its own.
    def attach_folder_node(user, project, name:, node_id:, role: "model", parent: nil)
      folder_file!(user, project, name:, node_id:, parent:)
      project.file_attachments.create!(user:, node_id:, role:)
    end

    # A folder file the THUMBNAIL PATH will really act on. `Maker::Previews::ThumbnailMap` asks the
    # port for a content token and skips any node that has none, so a token-less fixture measures
    # NOTHING — the trap maker_page_thumbnails_test.rb and page_query_budget_test.rb both record
    # (the latter was budgeting a path that never executed). Both columns are set, so this reads the
    # same on every backend: `content_hash` is share's and s3's token, `current_version_id` is
    # chunk_remote's. The name still has to be one a renderer claims, or the backfill skips it for
    # that reason instead.
    def previewable_folder_file!(user, project, name:, node_id:, parent: nil)
      node = folder_file!(user, project, name:, node_id:, parent:)
      node.update!(size: 5, mtime: 1_000_000_000,
                   content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
      node
    end

    # A subfolder inside the project's own folder, by name — the unit this page now sections by.
    def subfolder!(user, project, name:, node_id: SecureRandom.uuid, parent: nil)
      folder = project.ensure_library_folder!(user)
      user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent || folder.node_id)
    end

    # --- what the last sweep did (stage 4, S4-2) ---------------------------------------------

    # STORY 1.5 — the sweep reports on the page, not only to the log.
    test "the Files panel says what the last sweep filed" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project_folder_rows!(user, project)
      project.update_columns(last_swept_at: 2.hours.ago, last_sweep_moves: 3)

      get project_path(project)

      # "Filed", never "sweep" (2026-11-02, the UX audit's C3): the pass is filing to a maker.
      assert_select "p.sweep-note", /Filed 3 files/
      assert_select "p.sweep-note", /2 hours ago/
      assert_select "p.sweep-note", text: /sweep/i, count: 0
    end

    test "a sweep that moved nothing says nothing" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project_folder_rows!(user, project)
      project.update_columns(last_swept_at: 2.hours.ago, last_sweep_moves: 0)

      get project_path(project)

      assert_select "p.sweep-note", count: 0
    end

    test "a project with automatic filing off says so where the files are" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project_folder_rows!(user, project)
      project.update!(autofile: false)

      get project_path(project)

      assert_select "p.sweep-note", /Automatic filing is off/
      assert_select "p.sweep-note a[href=?]", edit_project_path(project)
    end

    # A HUB TILE OPENS THE FILE — its file page, never the Library with the file selected, which is
    # where it went until the owner asked for it to just open (2026-10-20). Both an attached folder
    # file and one nothing attached, because the folder is the relation for the second.
    test "attached files render as tiles opening the file" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      attach_node(user, project, name: "base.stl", node_id: "n-1", role: "model")
      folder = project.folder_node_id
      user.nodes.create!(node_id: "n-lid", name: "lid.stl", kind: "file", parent_node_id: folder)

      get project_path(project)
      assert_response :success
      assert_select ".attachments-panel .attachment-group .attachment-tile", 2
      assert_select ".attachment-group .attachment-tile a[href=?]", file_path("n-1")
      assert_select ".attachment-group .attachment-tile a[href=?]", file_path("n-lid")
      assert_select ".attachment-tile a[href*='selected=']", 0
    end

    # WAS: "degrades to an unavailable placeholder". That placeholder was the bug — a file deleted
    # from the share sat in every project it was attached to forever, as a ⚠️ tile with a Remove
    # button nobody was going to click once per project. It leaves the panel now; the row itself is
    # destroyed later by Maker::AttachmentReaper, once the tombstone's undo window has closed.
    test "a deleted attached node leaves the project's Files panel entirely" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # Attachment row whose node_id has no live Node (deleted / never present).
      ghost_attachment!(project, user:, node_id: "gone", role: "model", label: "ghost.stl")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-tile", count: 0
      assert_select ".attachment-tile.unavailable", count: 0
      assert_no_match(/ghost\.stl/, response.body)
    end

    # NOT SILENT, and this is the half that keeps "removed" from reading as "my files vanished":
    # the panel says how many left and points at the Trash, so a user who deleted one by accident
    # has somewhere to go. It disappears on its own when the reaper clears the rows.
    test "the panel says how many attachments left, rather than removing them silently" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      attach_node(user, project, name: "bracket.stl", node_id: "n-live", role: "model")
      ghost_attachment!(project, user:, node_id: "gone", role: "model", label: "ghost.stl")

      get project_path(project)
      assert_select ".attachments-missing", text: /1 attached file no longer in your library/
      assert_select ".attachments-missing a[href=?]", trash_index_path
      # The live one is untouched — this is a filter, not an outage.
      assert_select ".attachment-tile .grid-name", text: "bracket.stl"
    end

    # An "empty" project and a project whose files were all deleted are DIFFERENT SENTENCES. Saying
    # "No files in this project yet" to someone who just deleted four is a lie about what happened.
    test "a project whose every file is gone explains itself instead of reading as empty" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      ghost_attachment!(project, user:, node_id: "gone", role: "model", label: "ghost.stl")

      get project_path(project)
      assert_select ".attachments-missing", text: /1 attached file no longer in your library/
      assert_select "p.muted", text: "No files attached yet.", count: 0
    end

    # --- the folder as a tree (stage 3, S3-1; folder panels 2026-09-08) ---------

    # THE HEADLINE SCENARIO: the Files panel holds the folder's ROOT, each DEPTH-ONE subfolder is
    # its own panel, and anything deeper is a folder tile inside its parent's panel that opens in
    # place (2026-11-24, click-through panels). No role vocabulary anywhere, at either level.
    test "loose files stay in Files, each subfolder is a panel, and a nested one is a folder tile inside it" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      models = subfolder!(user, project, name: "models", node_id: "d-models")
      docs = subfolder!(user, project, name: "docs", node_id: "d-docs")
      wiring = subfolder!(user, project, name: "wiring", node_id: "d-wiring", parent: docs.node_id)
      folder_file!(user, project, name: "notes.txt", node_id: "n-notes")
      folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket", parent: models.node_id)
      folder_file!(user, project, name: "manual.pdf", node_id: "n-manual", parent: docs.node_id)
      folder_file!(user, project, name: "pinout.pdf", node_id: "n-pinout", parent: wiring.node_id)

      get project_path(project)
      assert_response :success

      # Loose stays in Files, and it names why these files sit apart.
      assert_select ".attachments-panel .attachment-group-head", text: /Loose \(1\)/
      assert_select ".attachments-panel .attachment-group .grid-name", text: "notes.txt"
      assert_select ".attachments-panel p.loose-note", text: /Loose files are filed into their folders on the next scan/

      assert_select "section.folder-panel[id=?] .panel-head", "folder:d-models" do
        assert_select "h2", text: "models"
        assert_select ".mono.muted", text: "1 file"
      end
      # docs NESTS wiring — a folder tile INSIDE the docs PANEL, and the count in the panel head is
      # the whole subtree (its own manual.pdf plus wiring/pinout.pdf).
      assert_select "section.folder-panel[id=?] .panel-head .mono.muted", "folder:d-docs", text: "2 files"
      assert_select "section.folder-panel[id=?]", "folder:d-docs" do
        assert_select ".folder-tile .grid-name", text: "wiring"
        assert_select ".folder-tile .folder-tile-count", text: "1 file"
        assert_select ".attachment-tile .grid-name", text: "manual.pdf"
        assert_select ".attachment-tile .grid-name", { text: "pinout.pdf", count: 0 }, "a subfolder's files wait for it to be opened"
      end
      assert_select "section.folder-panel[id=?] > div > .attachments-grid .grid-name", "folder:d-docs",
                    text: "manual.pdf"
      assert_select ".attachment-tile .grid-name", text: "bracket.stl"
    end

    test "an empty subfolder is a quiet panel of its own, and the project is not called empty" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      subfolder!(user, project, name: "empty", node_id: "d-empty")

      get project_path(project)
      assert_response :success
      assert_select "section.folder-panel.panel--quiet[id=?] .panel-head h2", "folder:d-empty", text: "empty"
      assert_select "section.folder-panel[id=?] p.muted", "folder:d-empty", text: "Empty folder."
      assert_select "p.muted", text: /No files in this project yet/, count: 0
    end

    # A NESTED REPOSITORY IS A FOLDER TILE, BADGED, AND OPENING IT SHOWS ITS CARD AND ITS FILES
    # (2026-11-24, click-through panels). It used to be the one section that rendered closed over a
    # Finder browser; inside a Tiles or List panel it is a folder like any other now, and the card
    # (README, latest commit, Commits/History) leads it once it is open. NESTED IS THE WHOLE FIXTURE:
    # at DEPTH ONE a repository is a panel that opens in the browser (the case below).
    test "a nested repository is a folder tile, badged, and opening it shows its card and its files" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      code = subfolder!(user, project, name: "code", node_id: "d-code")
      firmware = user.nodes.create!(node_id: "d-firmware", name: "firmware", kind: "dir",
                                    parent_node_id: code.node_id)
      user.nodes.create!(node_id: "d-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                         parent_node_id: firmware.node_id)
      src = user.nodes.create!(node_id: "d-src", name: "src", kind: "dir", parent_node_id: firmware.node_id)
      folder_file!(user, project, name: "main.c", node_id: "n-mainc", parent: firmware.node_id)
      folder_file!(user, project, name: "led.c", node_id: "n-ledc", parent: src.node_id)

      get project_path(project)
      assert_response :success
      assert_select "section.folder-panel[id=?]", "folder:d-code" do
        assert_select ".folder-tile .grid-name", text: "firmware"
        # THE WHOLE SUBTREE, 2 — not the 1 file at its own root — with the badge beside it.
        assert_select ".folder-tile .folder-tile-count", text: /\A2 files/
        assert_select ".folder-tile .folder-tile-count .badge", text: "repo"
        assert_select ".folder-tile a[href=?][data-turbo-frame=?]", project_path(project, at: { "d-code" => "d-firmware" }),
                      "frame-folder-d-code"
        assert_select ".attachment-tile .grid-name", { text: "main.c", count: 0 }
        assert_select ".repo-browser", 0, "no closed browser any more"
      end

      get project_path(project, at: { "d-code" => "d-firmware" })
      assert_response :success
      assert_select "section.folder-panel[id=?]", "folder:d-code" do
        assert_select "nav.folder-path .folder-path-here", text: "firmware"
        assert_select ".repo-card" do
          assert_select "a[href=?]", repo_commit_path(firmware.node_id)
          assert_select "a[href=?]", repo_history_path(firmware.node_id)
        end
        assert_select ".folder-tile .grid-name", text: "src"
        assert_select ".attachment-tile .grid-name", text: "main.c"
        assert_select ".attachment-tile .grid-name", { text: "led.c", count: 0 }
        assert_select ".repo-browser", 0
      end
      # No standalone Repositories group, and no closed section either.
      assert_select ".attachment-group-head", text: /Repositories/, count: 0
    end

    # A REPOSITORY AT DEPTH ONE IS A PANEL (2026-09-08; spec decisions 3 and 6), and its DEFAULT
    # VIEW is the browser, with the panel head carrying the badge and the Commits/History links.
    test "a depth-one repository is a panel that opens in the browser, badged, with Commits and History" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project.ensure_library_folder!(user)
      firmware = user.nodes.create!(node_id: "d-firmware", name: "firmware", kind: "dir",
                                    parent_node_id: folder.node_id)
      user.nodes.create!(node_id: "d-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                         parent_node_id: firmware.node_id)
      src = user.nodes.create!(node_id: "d-src", name: "src", kind: "dir", parent_node_id: firmware.node_id)
      folder_file!(user, project, name: "main.c", node_id: "n-mainc", parent: firmware.node_id)
      folder_file!(user, project, name: "led.c", node_id: "n-ledc", parent: src.node_id)

      get project_path(project)
      assert_response :success
      assert_select "section.folder-panel[id=?]", "folder:d-firmware" do
        assert_select ".panel-head h2", text: "firmware"
        assert_select ".panel-head span.badge", text: "repo"
        assert_select ".panel-head .mono.muted", text: "2 files"
        assert_select ".panel-head a[href=?]", repo_commit_path(firmware.node_id)
        assert_select ".panel-head a[href=?]", repo_history_path(firmware.node_id)
        assert_select ".repo-browser[data-filebrowser-root-value=?]", firmware.node_id
      end
      # NOT UNROLLED: no tile for its own file, and no folder tile for its subdirectory.
      assert_select ".attachment-tile .grid-name", text: "main.c", count: 0
      assert_select ".folder-tile", count: 0
    end

    test "folder files do not get Detach" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      attach_folder_node(user, project, name: "bracket.stl", node_id: "n-bracket", role: "model")

      get project_path(project)
      assert_response :success
      # The Loose group's tile; the same file is also the recent row's only tile (slice 6), and
      # neither carries the corner.
      assert_select ".attachment-group .attachment-tile", 1
      assert_select ".attachment-tile .tile-detach", count: 0
      assert_select ".attachment-tile .tile-meta", count: 0
    end

    test "the panel caps at FILE_CAP and points at the folder" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project.ensure_library_folder!(user)
      now = Time.current
      Node.insert_all((Maker::ProjectFolderListing::FILE_CAP + 1).times.map do |i|
        { node_id: "cap-#{i}", name: format("f%03d.stl", i), kind: "file", user_id: user.id,
          parent_node_id: folder.node_id, deleted: false, created_at: now, updated_at: now }
      end)

      get project_path(project)
      assert_response :success
      # THE GROUPS' TILES: the recent row above them draws its own 8 by design (slice 6), and is
      # not part of the cap this pins.
      assert_select ".attachment-group .attachment-tile", Maker::ProjectFolderListing::FILE_CAP
      # `text:` on the LINK selector below checks the link's own text ("Open the folder"), not the
      # paragraph's — the count sentence is asserted on the paragraph itself.
      assert_select ".attachments-truncated", text: /Showing 300 of 301/
      assert_select ".attachments-truncated a[href=?]", files_path(folder: folder.node_id),
                    text: "Open the folder"
    end

    # THE LIVE CASE (2026-11-12): a 612-file project showed five of its seven folder panels as
    # "0 files · Empty folder", because the cap went to the first 300 names across the whole folder
    # and those folders' names sorted late. Here every "a…" file sorts before Accessories' one file.
    test "a folder cut by the cap counts its real files and says so, and no other panel is starved" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      big = subfolder!(user, project, name: "Centerpieces", node_id: "d-big")
      rings = subfolder!(user, project, name: "rings", node_id: "d-rings", parent: big.node_id)
      late = subfolder!(user, project, name: "Accessories", node_id: "d-late")
      now = Time.current
      Node.insert_all([ [ "big", big ], [ "ring", rings ] ].flat_map do |prefix, parent|
        300.times.map do |i|
          { node_id: "#{prefix}-#{i}", name: format("a%03d.stl", i), kind: "file", user_id: user.id,
            parent_node_id: parent.node_id, deleted: false, created_at: now, updated_at: now }
        end
      end)
      folder_file!(user, project, name: "z-hook.stl", node_id: "n-hook", parent: late.node_id)

      get project_path(project)
      assert_response :success

      assert_select "section.folder-panel[id=?]", "folder:d-late" do
        assert_select ".panel-head .mono.muted", text: "1 file"
        assert_select ".attachment-tile .grid-name", text: "z-hook.stl"
        assert_select "p.muted", { text: "Empty folder.", count: 0 }
      end
      # ONLY THE OPEN FOLDER'S OWN FILES SHARE THE TILES (2026-11-24): Centerpieces' 300, Accessories'
      # 1 and the empty root split FILE_CAP, so Centerpieces draws 299. Its subfolder `rings` is a
      # tile that counts its real 300, loaded from the second pot.
      assert_select "section.folder-panel[id=?]", "folder:d-big" do
        assert_select ".panel-head .mono.muted", text: "600 files"
        assert_select ".attachment-tile", 299
        assert_select ".attachments-truncated", text: /Showing 299 of 300 files in this folder\./
        assert_select ".attachments-truncated a[href=?]", files_path(folder: "d-big"), text: "Open the folder"
        assert_select ".folder-tile .grid-name", text: "rings"
        assert_select ".folder-tile .folder-tile-count", text: "300 files"
      end
      assert_select ".attachments-panel .attachments-truncated", text: /Showing 600 of 601/

      # OPENED, the cut folder says where the rest are: the folder itself, not the panel's.
      get project_path(project, at: { "d-big" => "d-rings" })
      assert_select "section.folder-panel[id=?]", "folder:d-big" do
        assert_select ".panel-head .mono.muted", { text: "600 files" }, "the head still counts the panel's own folder"
        assert_select ".attachment-tile", 299
        assert_select ".attachments-truncated", text: /Showing 299 of 300 files in this folder\./
        assert_select ".attachments-truncated a[href=?]", files_path(folder: "d-rings"), text: "Open the folder"
      end
      assert_select "section.folder-panel[id=?] .attachment-tile .grid-name", "folder:d-late", text: "z-hook.stl"
    end

    # THE LIVE CASE (2026-11-23): `pc case`'s `out` panel drew 160 of its 173 files while two panels
    # in the browser view, which draw no tiles at all, took 105 of the page's 300.
    test "a folder in the browser view takes none of the tiles from a tiles panel beside it" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      cad = subfolder!(user, project, name: "cad", node_id: "d-cad")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      now = Time.current
      Node.insert_all([ [ "cad", cad, 120 ], [ "out", out, 250 ] ].flat_map do |prefix, parent, n|
        n.times.map do |i|
          { node_id: "#{prefix}-#{i}", name: format("#{prefix}%03d.stl", i), kind: "file", user_id: user.id,
            parent_node_id: parent.node_id, deleted: false, created_at: now, updated_at: now }
        end
      end)
      project.update!(panels: { "views" => { "folder:d-cad" => "browser" } })

      get project_path(project)
      assert_response :success

      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select ".panel-head .mono.muted", text: "250 files"
        assert_select ".attachment-tile", 250
        assert_select ".attachments-truncated", count: 0
      end
      assert_select "section.folder-panel[id=?]", "folder:d-cad" do
        assert_select ".panel-head .mono.muted", text: "120 files"
        assert_select ".repo-browser[data-filebrowser-root-value=?]", "d-cad"
      end
      assert_select ".attachments-panel .attachments-truncated", count: 0
    end

    # A SUBFOLDER NOBODY OPENED TAKES NONE OF THE TILES (2026-11-24, click-through panels): a panel shows
    # one folder at a time, so only the open folder's own files share FILE_CAP. Under #554's tree-fair
    # split `out`'s 280 would have shared its 300 with `deep`'s 200 and drawn 150.
    test "a subfolder's files take none of the tiles until it is opened" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      deep = subfolder!(user, project, name: "deep", node_id: "d-deep", parent: out.node_id)
      now = Time.current
      Node.insert_all([ [ "out", out, 280 ], [ "deep", deep, 200 ] ].flat_map do |prefix, parent, n|
        n.times.map do |i|
          { node_id: "#{prefix}-#{i}", name: format("#{prefix}%03d.stl", i), kind: "file", user_id: user.id,
            parent_node_id: parent.node_id, deleted: false, created_at: now, updated_at: now }
        end
      end)

      get project_path(project)
      assert_response :success
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select ".panel-head .mono.muted", text: "480 files"
        assert_select ".attachment-tile", 280, "the open folder's own files, all of them"
        assert_select ".folder-tile .folder-tile-count", text: "200 files"
        assert_select ".attachments-truncated", 0
      end
    end

    # ONE FOLDER AT A TIME, AND THE URL SAYS WHICH (2026-11-24, click-through panels; spec §1).
    # `?at[<panel id>]=<node id>` opens a folder beneath a panel, a path bar walks back up, and every
    # link carries every other panel's open folder.
    test "opening folders in a panel shows a path back up, and every other panel stays where it was" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      itx = subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)
      four = subfolder!(user, project, name: "four-piece", node_id: "d-four", parent: itx.node_id)
      docs = subfolder!(user, project, name: "docs", node_id: "d-docs")
      old = subfolder!(user, project, name: "old", node_id: "d-old", parent: docs.node_id)
      folder_file!(user, project, name: "foot.stl", node_id: "n-foot", parent: four.node_id)
      folder_file!(user, project, name: "summary.json", node_id: "n-summary", parent: itx.node_id)
      folder_file!(user, project, name: "v1.pdf", node_id: "n-v1", parent: old.node_id)

      get project_path(project)
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select "nav.folder-path", 0, "a panel at its own folder needs no path"
        assert_select ".folder-tile a[href=?][data-turbo-frame=?][data-turbo-action=advance]",
                      project_path(project, at: { "d-out" => "d-itx" }), "frame-folder-d-out"
      end
      # THE FRAME IS `_top`: every other link inside it navigates the page, as it did before.
      assert_select "turbo-frame[id=?][target=_top] > section.folder-panel[id=?]", "frame-folder-d-out", "folder:d-out"

      get project_path(project, at: { "d-out" => "d-four", "d-docs" => "d-old" })
      assert_response :success
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select "nav.folder-path a", 2
        assert_select "nav.folder-path a[href=?][data-turbo-frame=?]", project_path(project, at: { "d-docs" => "d-old" }),
                      "frame-folder-d-out", text: "out"
        assert_select "nav.folder-path a[href=?]", project_path(project, at: { "d-out" => "d-itx", "d-docs" => "d-old" }), text: "itx"
        assert_select "nav.folder-path .folder-path-here[aria-current=location]", text: "four-piece"
        assert_select ".attachment-tile .grid-name", text: "foot.stl"
        assert_select ".attachment-tile .grid-name", text: "summary.json", count: 0
        assert_select ".panel-head h2", { text: "out" }, "the head still names the panel's own folder"
      end
      assert_select "section.folder-panel[id=?] .attachment-tile .grid-name", "folder:d-docs", text: "v1.pdf"
    end

    test "an at the walk cannot place leaves the panel at its own folder" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)
      docs = subfolder!(user, project, name: "docs", node_id: "d-docs")
      folder_file!(user, project, name: "top.stl", node_id: "n-top", parent: out.node_id)

      [ "no-such-node", docs.node_id, "n-top", out.node_id ].each do |target|
        get project_path(project, at: { "d-out" => target })
        assert_response :success
        assert_select "section.folder-panel[id=?]", "folder:d-out" do
          assert_select "nav.folder-path", 0, "#{target} is not a folder beneath out"
          assert_select ".attachment-tile .grid-name", text: "top.stl"
        end
      end
      # NOT A STRING: an array or a hash where a node id belongs is no folder either.
      get project_path(project) + "?at[d-out][]=d-itx"
      assert_response :success
      assert_select "nav.folder-path", 0
      get project_path(project) + "?at=d-itx"
      assert_response :success
      assert_select "nav.folder-path", 0
    end

    test "a frame request answers the one panel, with the folder it opened" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      itx = subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)
      subfolder!(user, project, name: "docs", node_id: "d-docs")
      folder_file!(user, project, name: "summary.json", node_id: "n-summary", parent: itx.node_id)

      get project_path(project, at: { "d-out" => "d-itx" }), headers: { "Turbo-Frame" => "frame-folder-d-out" }
      assert_response :success
      assert_select "turbo-frame[id=?]", "frame-folder-d-out"
      assert_select "section.folder-panel", 1, "only the panel the frame names"
      assert_select "section.attachments-panel", 0
      assert_select ".attachment-tile .grid-name", text: "summary.json"
      # THE PAGE'S OWN HEAD: Turbo records the promoted visit only when the tracked head matches, and
      # copies the title in (layouts/turbo_rails/frame).
      assert_select "title", text: "Case — Tinkerex"
      assert_select "head link[rel=stylesheet][data-turbo-track=reload]", minimum: 1

      get project_path(project), headers: { "Turbo-Frame" => "frame-folder-no-such" }
      assert_select "section.attachments-panel", 1, "a frame id that names no panel gets the page"
      get project_path(project), headers: { "Turbo-Frame" => "folder:d-out" }
      assert_select "section.attachments-panel", 1, "a section id is not a frame id"
    end

    test "a list panel opens folders the same way" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      itx = subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)
      folder_file!(user, project, name: "top.stl", node_id: "n-top", parent: out.node_id)
      folder_file!(user, project, name: "deep.stl", node_id: "n-deep", parent: itx.node_id)
      project.update!(panels: { "views" => { "folder:d-out" => "list" } })

      get project_path(project)
      assert_select "section.folder-panel[id=?] table.project-files tbody", "folder:d-out" do
        assert_select "tr.folder-row:first-child a[href=?][data-turbo-frame=?][data-turbo-action=advance]",
                      project_path(project, at: { "d-out" => "d-itx" }), "frame-folder-d-out", text: /itx/
        assert_select "tr.folder-row td.col-size", text: "1 file"
        assert_select "tr a", text: "top.stl"
        assert_select "tr a", text: "deep.stl", count: 0
      end

      get project_path(project, at: { "d-out" => "d-itx" })
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select "nav.folder-path .folder-path-here", text: "itx"
        assert_select "table.project-files tr a", text: "deep.stl"
        assert_select "table.project-files tr.folder-row", 0
      end
    end

    test "the editor draws folder tiles that open nothing" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)

      get edit_layout_project_path(project, at: { "d-out" => "d-itx" })
      assert_response :success
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select ".folder-tile .grid-name", text: "itx"
        assert_select ".folder-tile a", 0
        assert_select "nav.folder-path", 0, "the editor opens no folder"
      end

      # NOR DOES A FRAME REQUEST: the editor's tiles cannot ask, and one that did gets the editor.
      get edit_layout_project_path(project), headers: { "Turbo-Frame" => "frame-folder-d-out" }
      assert_select "div.layout-editor[data-controller=layout-editor]", 1
    end

    test "a view switch keeps the panels where they were" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)

      get project_path(project, at: { "d-out" => "d-itx" })
      assert_select "section.folder-panel[id=?] .view-toggle form input[name=?][value=?]", "folder:d-out", "at[d-out]", "d-itx"
      patch project_panels_path(project), params: { view: { "folder:d-out" => "list" }, in_place: "1", at: { "d-out" => "d-itx" } }
      assert_redirected_to project_path(project, panel: "folder:d-out", at: { "d-out" => "d-itx" }, anchor: "folder:d-out")

      get project_path(project)
      assert_select ".view-toggle input[name^=at]", 0, "nothing open, nothing carried"
    end

    # THE RECENT ROW IS NOT THE CAPPED LISTING (slice 6). Its newest file here is the LAST by name,
    # so past FILE_CAP: absent from every group, present in the row — and its thumbnail must
    # backfill on this render, which needs its id in the page's one ThumbnailMap union AHEAD of the
    # 300 listed tiles (BACKFILL_LIMIT is spent in order, and is 100). Content tokens on every row,
    # or the map short-circuits before the backfill this asserts ever runs. It is also an addon's
    # output, so its right-click menu's "Edit in" needs its id in the ONE addon-origin lookup too.
    test "a recent file past FILE_CAP shows in the recent row, and its thumbnail backfills on the first render" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project_folder_rows!(user, project)
      day_ago = 1.day.ago
      Node.insert_all((Maker::ProjectFolderListing::FILE_CAP + 1).times.map do |i|
        { node_id: "cap-#{i}", name: format("f%03d.stl", i), kind: "file", user_id: user.id,
          parent_node_id: folder.node_id, deleted: false, size: 5, mtime: 1_000_000_000,
          content_hash: "h-cap-#{i}", current_version_id: "v-cap-#{i}", created_at: day_ago, updated_at: day_ago }
      end)
      last = "cap-#{Maker::ProjectFolderListing::FILE_CAP}"
      user.nodes.find_by!(node_id: last).update_columns(updated_at: Time.current)
      state = user.maker_addon_states.create!(addon_key: "boxes", name: "shelf box", data: {}, revision: 1)
      state.files.create!(node_id: last, role: "output", position: 0)
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        { "key" => "boxes", "title" => "Box Generator", "icon" => "📦", "description" => "Parametric boxes",
          "api_version" => "1", "entry" => "boxes.js" }
      ])

      get project_path(project)
      assert_response :success
      assert_equal "f300.stl", css_select(".recent-files .attachment-tile .grid-name").first&.text
      assert_select ".attachment-group .grid-name", { text: "f300.stl", count: 0 }, "past the cap, so in no group"
      assert user.maker_previews.exists?(node_id: last),
             "a recent tile past the cap must get its preview row on the render that draws it"
      assert_select ".recent-files .attachment-tile a[data-node-id=?][data-addon-open-url]", last
    ensure
      Maker::Addons::Source.reset!
    end

    # THE OTHER CAP. A walk that stops at DIR_CAP subfolders before it has seen a single file must
    # not read as an empty project: the truncation line renders OUTSIDE the empty check, and names
    # the subfolders rather than a "0 of 0" file count (found in review, 2026-09-04).
    test "a walk cut short by DIR_CAP says so even when no file made the list" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project.ensure_library_folder!(user)
      now = Time.current
      Node.insert_all((Maker::ProjectFolderListing::DIR_CAP + 1).times.map do |i|
        { node_id: "dcap-#{i}", name: format("sub%03d", i), kind: "dir", user_id: user.id,
          parent_node_id: folder.node_id, deleted: false, created_at: now, updated_at: now }
      end)

      get project_path(project)
      assert_response :success
      assert_select "p.muted", text: /No files in this project yet/, count: 0
      assert_select ".attachments-truncated", text: /Not every subfolder was listed/
      assert_select ".attachments-truncated", text: /Showing/, count: 0
      assert_select ".attachments-truncated a[href=?]", files_path(folder: folder.node_id)
    end

    # LINKED IS A FOLDER QUESTION, NOT A LIST QUESTION. The listing is capped at FILE_CAP, so an
    # attached file past the cap is absent from the tiles — and must NOT come back as "linked from
    # elsewhere": it sits in the folder, and the truncation line stands for it. The controller asks
    # the tree (`ProjectFolderListing#contains?`), never the capped id set; asking the set instead
    # renders exactly the phantom Linked group this test forbids.
    test "an attached file past the cap is in the folder, not linked" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project.ensure_library_folder!(user)
      now = Time.current
      Node.insert_all((Maker::ProjectFolderListing::FILE_CAP + 1).times.map do |i|
        { node_id: "cap-#{i}", name: format("f%03d.stl", i), kind: "file", user_id: user.id,
          parent_node_id: folder.node_id, deleted: false, created_at: now, updated_at: now }
      end)
      # f300.stl sorts last, past the cap of 300 tiles.
      project.file_attachments.create!(user:, node_id: "cap-#{Maker::ProjectFolderListing::FILE_CAP}", role: "model")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-group-head", text: /Linked/, count: 0
      assert_select ".project-stats", text: /linked/, count: 0
      assert_select ".attachments-truncated", text: /Showing 300 of 301/
    end

    # NO "LINKED FROM ELSEWHERE" (2026-11-19, the owner's call): a file attached to the project but
    # living outside its folder is not drawn on the page at all, and the stats line does not count it.
    test "a file attached from outside the folder is not drawn" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project_folder_rows!(user, project)
      # A FILE OF THE FOLDER'S OWN, the control: without one the panel says "No files in this project
      # yet" and draws no group at all, so the absence below would hold over a page that never got
      # as far as drawing tiles.
      user.nodes.create!(node_id: "n-home", name: "home.stl", kind: "file", parent_node_id: folder.node_id)
      user.nodes.create!(node_id: "n-away", name: "elsewhere.stl", kind: "file")
      project.file_attachments.create!(user:, node_id: "n-away", role: "model")

      get project_path(project)
      assert_response :success
      assert_select ".attachments-panel .attachment-tile .grid-name", text: "home.stl"
      # NOT `response.body`: the head's cover still falls back to the first attached file wherever it
      # lives (projects/_hero), which is the cover's rule, not a group's.
      assert_select ".attachment-tile .grid-name", text: "elsewhere.stl", count: 0
      assert_select "table.project-files td.col-name", text: "elsewhere.stl", count: 0
      assert_no_match "Linked from elsewhere", response.body
      assert_select ".project-stats", text: /linked/, count: 0
      assert_select ".tile-detach, .tile-move", count: 0
    end

    # A GENUINELY EMPTY PROJECT (no folder files, no linked attachments, no subfolders, nothing
    # missing), as opposed to "a project whose every file is gone" above (which HAS a missing
    # attachment and explains itself differently). ensure_library_folder! still runs on #show, so
    # @listing.available? is true and the sentence names the folder path.
    test "a genuinely empty project says so, not that files were attached" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      get project_path(project)
      assert_response :success
      assert_select "p.muted", text: /\ANo files in this project yet\./
    end

    # --- attach existing + detach ----------------------------------------------

    test "attach picker lists the user's recent files and searches by name" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      user.nodes.create!(node_id: "f-2", name: "manual.pdf", kind: "file")

      get new_project_attachment_path(project)
      assert_response :success
      assert_select ".picker-result", 2

      get new_project_attachment_path(project), params: { q: "bracket" }
      assert_select ".picker-result", 1
      assert_select ".picker-result", text: /bracket.stl/
    end

    # Each pair shares its prefix, so both halves carry weight: without `ESCAPE '\'` SQLite matches
    # sanitize_sql_like's backslash literally and the search finds nothing; without the sanitizing,
    # `%` and `_` are wildcards and the search finds both. The count is asserted ON ITS OWN, because
    # `text:` filters before `count:` counts — `count: 1, text: "x"` passes with a stray row beside x.
    test "the attach picker's search treats % and _ as literals" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-pct", name: "100%-infill.stl", kind: "file")
      user.nodes.create!(node_id: "f-num", name: "100-infill.stl", kind: "file")
      user.nodes.create!(node_id: "f-und", name: "m3_8.stl", kind: "file")
      user.nodes.create!(node_id: "f-dash", name: "m3-8.stl", kind: "file")

      get new_project_attachment_path(project), params: { q: "100%" }
      assert_select ".picker-result", 1
      assert_select ".picker-result .picker-name", text: "100%-infill.stl"

      get new_project_attachment_path(project), params: { q: "m3_8" }
      assert_select ".picker-result", 1
      assert_select ".picker-result .picker-name", text: "m3_8.stl"
    end

    test "attach creates a reference with an inferred role" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")

      assert_difference "project.file_attachments.count", 1 do
        post project_attachments_path(project), params: { node_id: "f-1" }
      end
      assert_equal "model", project.file_attachments.last.role   # .stl -> model
      assert_redirected_to project_path(project)
    end

    test "attach refuses a node the user does not own" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      other = User.create!(email: "z@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "secret.stl", kind: "file")

      assert_no_difference "Maker::FileAttachment.count" do
        post project_attachments_path(project), params: { node_id: "theirs" }
      end
      assert_redirected_to new_project_attachment_path(project)
    end

    test "detach removes the reference but never the library node" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      att = project.file_attachments.create!(user:, node_id: "f-1", role: "model")

      assert_difference "Maker::FileAttachment.count", -1 do
        delete attachment_path(att)
      end
      assert user.nodes.present.exists?(node_id: "f-1"), "the library file must survive a detach"
      assert_redirected_to project_path(project)
    end

    test "the photo picker keeps entry_id through a search so photos attach to the entry" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "x")
      user.nodes.create!(node_id: "img-1", name: "clamp.png", kind: "file")

      get new_project_attachment_path(project, entry_id: entry.id, q: "clamp")
      assert_response :success
      assert_select "form.picker-search input[name=entry_id][value=?]", entry.id.to_s
      assert_select ".picker-result form[action=?]", entry_photos_path(entry)
    end

    # --- collapsible sections + LightBurn/MillMage backups ----------------------

    # LightBurn and MillMage drop a `<stem>_backup.<ext>` rescue copy beside every project file, so
    # a laser-heavy project's panel was half rescue copies of the design next to it. They move to
    # their own CLOSED section rather than being dropped: the file is really in the project's
    # folder, and a panel that hid it would be lying about what is on disk.
    test "LightBurn backups move to a collapsed Backups section, out of their own subfolder" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      laser = subfolder!(user, project, name: "laser", node_id: "d-laser")
      # Backup detection (Row#backup?) reads the node's own name, wherever it sits in the tree.
      folder_file!(user, project, name: "sign.lbrn2", node_id: "n-sign", parent: laser.node_id)
      folder_file!(user, project, name: "sign_backup.lbrn2", node_id: "n-bak", parent: laser.node_id)
      # WITH THE LASER PANEL'S STACKS OFF. Since version stacks (Shop manual spec §9) a backup of a
      # file beside it is a member of that file's stack in a stacking panel, and leaves Backups —
      # version_stacks_pages_test.rb pins that side. This pins the diversion itself, which is what
      # every panel with its stacks off, and every backup that stacks with nothing, still gets.
      project.update!(panels: { "unstacked" => [ "folder:d-laser" ] })

      get project_path(project)
      # THE LASER PANEL COUNTS ONE FILE, not two: the backup was diverted out of the tree entirely,
      # so it is neither in the panel's count nor among its tiles.
      assert_select "section.folder-panel[id=?] .panel-head .mono.muted", "folder:d-laser", text: "1 file"
      # Backups stays a CROSS-CUTTING group in Files, wherever its files physically sit.
      assert_select ".attachments-panel .attachment-group-head", text: /Backups \(1\)/
      # CLOSED, which is the whole of "don't show the backups" — one click away, not gone (its
      # tile is still IN the markup, same as any other <details> content, just not the default
      # open state — assert_select sees it either way).
      assert_select ".attachment-group details:not([open]) summary", text: /Backups/
      # THE FILE ITSELF RENDERS EXACTLY ONCE, and NOT inside the laser panel it physically sits
      # in -- Backups pulls it out rather than duplicating it.
      assert_select ".attachment-tile .grid-name", text: "sign_backup.lbrn2", count: 1
      laser_panel = css_select("section.folder-panel[id='folder:d-laser']").first
      assert laser_panel, "expected a panel for the laser folder"
      assert_no_match(/sign_backup\.lbrn2/, laser_panel.text, "the backup must not also render inside laser")
    end

    # THE NARROWNESS IS THE POINT. A user's own `battery_backup.stl` is not a LightBurn rescue copy,
    # and filing it as one would hide a real design file behind a collapsed section. Both halves of
    # the rule (the suffix AND the extension) have to hold.
    test "a file merely named _backup in another format is not treated as a backup" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder_file!(user, project, name: "battery_backup.stl", node_id: "n-bat")

      get project_path(project)
      assert_select "p.loose-note"
      assert_select ".attachment-tile .grid-name", text: "battery_backup.stl"
      assert_select ".attachment-group-head", text: /Backups/, count: 0
    end

    # --- pointers (stage 3, S3-1) -----------------------------------------------

    # A STRAY *.ptr POINTER STUB RENDERS NOWHERE — Node.visible_entries excludes it unconditionally
    # (never a scan skip: it stays in the catalog, only hidden from display — see node.rb). The
    # sibling it points at is unaffected.
    test "a .ptr pointer stub beside its real file renders nowhere on the page" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket")
      folder_file!(user, project, name: "bracket.stl.ptr", node_id: "n-ptr")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-tile .grid-name", text: "bracket.stl"
      assert_no_match(/bracket\.stl\.ptr/, response.body)
      assert_select ".loose-note", text: /Loose files are filed into their folders on the next scan/
      # ONE tile, ONE file counted -- the pointer is not a second, merely-hidden row. In the recent
      # row too (slice 6): the pointer is no more a recent file than a listed one.
      assert_select ".attachment-group .attachment-tile", 1
      assert_select ".recent-files .attachment-tile", 1
      assert_select ".attachment-group-head", text: /Loose \(1\)/
    end

    # --- the list view (stage 3, S3-1; per panel since 2026-09-08) --------------

    # THE CHOICE IS PERSISTED ON THE ROW, NOT IN A COOKIE (spec decision 6): the page-wide
    # `project_view` cookie and its `?view=` link retired with the page-wide toggle, so the stored
    # view is what this drives — and it is remembered across a bare request by construction.
    test "a panel in list view renders a table with Section and Origin cells, and the choice is remembered" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      models = subfolder!(user, project, name: "models", node_id: "d-models")
      folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket", parent: models.node_id)
      project.update!(panels: { "views" => { "folder:d-models" => "list" } })

      get project_path(project)
      assert_response :success
      assert_select "section.folder-panel[id=?]", "folder:d-models" do
        assert_select "table.table.project-files"
        assert_select "table.project-files td.col-section", text: "models"
        assert_select "table.project-files td.col-origin", text: "—"
        assert_select ".view-toggle button.toggle.active", text: "List"
        # THE NAME OPENS THE FILE, the tile's own target.
        assert_select "table.project-files td.col-name a[href=?]", file_path("n-bracket"), text: "bracket.stl"
        assert_select "table.project-files a[href*='selected=']", 0
      end

      # A BARE `?view=list` IS INERT NOW. The old url survived in bookmarks and would otherwise
      # half-work — it must change nothing at all, not switch the page one last time.
      get project_path(project, view: "list")
      assert_select "section.attachments-panel table.project-files", count: 0
    end

    # A LIST ROW CARRIES THE TILE'S RIGHT-CLICK MENU (stage 4, S4-1). The two views draw the same
    # Row through two partials, so the menu's seven-key wire contract (docs/invariants/
    # files-preview.md) was on the tile alone and switching to List silently lost Note, Download
    # and "Edit in <addon>" — the same shape file_menu_wiring_test.rb records for the Files grid.
    # Asserted on the RENDERED attributes rather than on the helper, because a row that builds the
    # hash and never emits it looks identical to a unit test.
    test "list rows carry the same context-menu data as tiles" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder_file!(user, project, name: "plate.svg", node_id: "f1")
      project.update!(panels: { "views" => { "attachments" => "list" } })

      get project_path(project)

      assert_response :success
      assert_select "table.project-files tr[data-action=?][data-note-url=?][data-download-url=?]",
                    "contextmenu->filemenu#open", file_notes_path("f1"), blob_file_path("f1", download: 1)
    end

    # TILES IS THE DEFAULT AND THE TOGGLE IS A WRITE. Two buttons on the Files panel — `browser`
    # is not offered here (projects/_attachments' header says why) — each posting `view[attachments]`
    # to the panels door, which is the field name a browser will really send.
    test "tiles is the default view, and the Files toggle posts view[attachments] to the panels door" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket")

      get project_path(project)
      assert_select ".attachments-panel .view-toggle button.toggle.active", text: "Tiles"
      assert_select ".attachments-panel .attachments-grid .attachment-tile"
      assert_select ".attachments-panel .view-toggle form[action=?]", project_panels_path(project), 2
      assert_select ".attachments-panel input[type=hidden][name=?][value=?]", "view[attachments]", "list"

      patch project_panels_path(project), params: { view: { "attachments" => "list" } }
      get project_path(project)
      assert_select ".attachments-panel table.project-files"
      assert_select ".attachments-panel .view-toggle button.toggle.active", text: "List"
    end

    # --- Thumbnails inside a closed repository (2026-09-07) ---------------------

    # A CLOSED REPOSITORY'S FILES ARE NOT IN THE PAGE'S THUMBNAIL UNION, AND THIS IS A REQUEST TEST
    # BECAUSE ONLY A REQUEST CAN SEE IT. `Maker::Previews::ThumbnailMap.for` does not merely look:
    # it BACKFILLS, creating a preview row and enqueueing a render job for every id it is handed
    # that has none. While a repository rendered tiles that was work the page used; since it became
    # a browser (the case above) it is a render per file for a picture the page never draws —
    # probed at 60 jobs from a page showing none of them. The unit underneath, `Dir#subtree_file_ids`,
    # can be perfect while the controller still hands the ids over, which is §14h's own lesson about
    # the 172 stale LightBurn thumbnails.
    #
    # A CONTROL, AND WITHOUT IT THIS PASSES ON A PAGE WHOSE THUMBNAIL PATH STOPPED RUNNING
    # ALTOGETHER: the loose file outside the repository must still get its row. A GENERATED file
    # inside the repository gets none either, since 2026-11-19: tool output is a file in its folder
    # like any other, and the Generated group that once tiled it wherever it sat is gone.
    #
    # THE FIXTURES CARRY A CONTENT TOKEN (previewable_folder_file!) — without one the port reports
    # no content and the whole path short-circuits before any of this runs.
    test "a repository's files enqueue no thumbnails, a generated one among them, while a loose file still does" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project.ensure_library_folder!(user)
      firmware = user.nodes.create!(node_id: "d-fw", name: "firmware", kind: "dir",
                                   parent_node_id: folder.node_id)
      user.nodes.create!(node_id: "d-fw-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                         parent_node_id: firmware.node_id)
      src = user.nodes.create!(node_id: "d-fw-src", name: "src", kind: "dir",
                               parent_node_id: firmware.node_id)
      # FIVE AT THE REPO'S ROOT AND FIVE ONE LEVEL DOWN: the subtree walk and the flat list are
      # different halves, and a fixture with only root files passes against a walk that never
      # recurses.
      repo_ids = (1..5).map { |i| previewable_folder_file!(user, project, name: "root#{i}.stl",
                                                           node_id: "n-root#{i}", parent: firmware.node_id).node_id } +
                 (1..5).map { |i| previewable_folder_file!(user, project, name: "deep#{i}.stl",
                                                           node_id: "n-deep#{i}", parent: src.node_id).node_id }
      loose = previewable_folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket").node_id
      generated = previewable_folder_file!(user, project, name: "panel.svg", node_id: "n-panel",
                                           parent: src.node_id).node_id
      state = user.maker_addon_states.create!(addon_key: "boxes", name: "front panel", data: {}, revision: 1)
      state.files.create!(node_id: generated, role: "output", position: 0)

      # EXACTLY ONE — the loose file. A count rather than `assert_no_enqueued_jobs`, which cannot be
      # scoped to a subset of node ids and would be red on the control this case needs.
      assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
        get project_path(project)
      end
      assert_response :success
      assert_equal 0, user.maker_previews.where(node_id: repo_ids).count,
                   "a closed repository's files were given preview rows by a page that draws no " \
                   "tile for any of them"
      assert user.maker_previews.exists?(node_id: loose), "the loose file's thumbnail must still backfill"
      assert_not user.maker_previews.exists?(node_id: generated),
                 "a generated file inside a closed repository draws no tile, like the files beside it"
    end

    # --- Tool output (no Generated group since 2026-11-19) -------------------------------

    # THE FIXTURE IDIOM FROM addon_origin_surfaces_test.rb: a Maker::AddonState + AddonFile tie a
    # node to a saved addon "thing". A FILE A TOOL MADE IS A FILE IN ITS FOLDER: it draws in that
    # folder's panel, its menu offers the tool, and the list's Origin column names it.
    test "a generated file draws in its own folder's panel, and no Generated group renders" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      models = subfolder!(user, project, name: "models", node_id: "d-models")
      node = folder_file!(user, project, name: "box.svg", node_id: "n-box", parent: models.node_id)
      state = user.maker_addon_states.create!(addon_key: "boxes", name: "shelf box", data: {}, revision: 3)
      state.files.create!(node_id: node.node_id, role: "output", position: 0)
      source = FakeAddonSource.new(manifests: [
        { "key" => "boxes", "title" => "Box Generator", "icon" => "📦", "description" => "Parametric boxes",
          "api_version" => "1", "entry" => "boxes.js" }
      ])
      Maker::Addons::Source.stub = source

      get project_path(project)
      assert_response :success
      assert_select ".generated-group", count: 0
      assert_no_match(/Generated \(/, response.body)
      assert_select "section.folder-panel[id=?] .attachment-tile .grid-name", "folder:d-models", text: "box.svg"
      assert_select "section.folder-panel[id=?] [data-addon-open-label=?]", "folder:d-models", "Edit in Box Generator"

      # THE LIST VIEW'S ORIGIN COLUMN IS THE TOOL'S TITLE, read from the origin hash's own key —
      # not a prefix stripped off the menu label, which a rewording would silently break (review).
      project.update!(panels: { "views" => { "folder:d-models" => "list" } })
      get project_path(project)
      assert_select "section.folder-panel[id=?] td.col-origin", "folder:d-models", text: "Box Generator"
    ensure
      Maker::Addons::Source.reset!
    end
  end
end
