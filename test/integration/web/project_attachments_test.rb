require "test_helper"
require_relative "../../support/fake_addon_source"

module Web
  class ProjectAttachmentsTest < ActionDispatch::IntegrationTest
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
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    # Seed a library node + attach it to a project via the model (attach UI is Task 6). THE NODE
    # SITS AT THE LIBRARY ROOT — outside any project's folder — which the folder-based panel
    # (Maker::ProjectFolderListing) makes the LINKED CASE: attached to this project, but not one of
    # its folder's own files. Kept under its original name because most of the tests below only
    # care that an attached, live file renders as a tile — which a Linked row still does.
    def attach_node(user, project, name:, node_id:, role: "model")
      user.nodes.create!(node_id:, name:, kind: "file")
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

    # A subfolder inside the project's own folder, by name — the unit this page now sections by.
    def subfolder!(user, project, name:, node_id: SecureRandom.uuid, parent: nil)
      folder = project.ensure_library_folder!(user)
      user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent || folder.node_id)
    end

    test "attached files render as tiles linking to the file view" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # attach_node's node sits at the library ROOT, outside the project's folder — the LINKED
      # CASE now (Row#linked? true) — and a Linked row still renders as an ordinary
      # .attachment-tile linking to the file view, which is all this test is pinning.
      attach_node(user, project, name: "base.stl", node_id: "n-1", role: "model")

      get project_path(project)
      assert_response :success
      assert_select ".attachments-panel .attachment-tile", 1
      assert_select ".attachment-tile a[href=?]", file_path("n-1")
    end

    # WAS: "degrades to an unavailable placeholder". That placeholder was the bug — a file deleted
    # from the share sat in every project it was attached to forever, as a ⚠️ tile with a Remove
    # button nobody was going to click once per project. It leaves the panel now; the row itself is
    # destroyed later by Maker::AttachmentReaper, once the tombstone's undo window has closed.
    test "a deleted attached node leaves the project's Files panel entirely" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # Attachment row whose node_id has no live Node (deleted / never present).
      project.file_attachments.create!(user:, node_id: "gone", role: "model", label: "ghost.stl")

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
      # attach_node's node sits at the library root — the Linked case now — and still renders as
      # an ordinary tile with a grid-name, which is all this test needs.
      attach_node(user, project, name: "bracket.stl", node_id: "n-live", role: "model")
      project.file_attachments.create!(user:, node_id: "gone", role: "model", label: "ghost.stl")

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
      project.file_attachments.create!(user:, node_id: "gone", role: "model", label: "ghost.stl")

      get project_path(project)
      assert_select ".attachments-missing", text: /1 attached file no longer in your library/
      assert_select "p.muted", text: "No files attached yet.", count: 0
    end

    # --- the folder as a tree (stage 3, S3-1) -----------------------------------

    # THE HEADLINE SCENARIO: sections are the folder's REAL subfolders, nested exactly as they sit
    # on disk — no role vocabulary anywhere in this panel any more. Loose (root) files come first.
    test "loose files come first, then one nested section per real subfolder" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      models = subfolder!(user, project, name: "models")
      docs = subfolder!(user, project, name: "docs")
      wiring = subfolder!(user, project, name: "wiring", parent: docs.node_id)
      folder_file!(user, project, name: "notes.txt", node_id: "n-notes")
      folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket", parent: models.node_id)
      folder_file!(user, project, name: "manual.pdf", node_id: "n-manual", parent: docs.node_id)
      folder_file!(user, project, name: "pinout.pdf", node_id: "n-pinout", parent: wiring.node_id)

      get project_path(project)
      assert_response :success

      # Loose first, and it names why these files sit apart.
      assert_select ".attachment-group-head", text: /Loose \(1\)/
      assert_select ".attachment-group .grid-name", text: "notes.txt"
      assert_select "p.loose-note", text: /Loose files are filed on the next sweep/

      assert_select ".file-tree-section details summary", text: /models \(1\)/
      assert_select ".file-tree-section details summary", text: /docs \(1\)/
      # docs NESTS wiring — a nested .file-tree-section INSIDE docs' own <details>, not merely
      # somewhere else on the page. `> details > summary` picks each section's OWN summary
      # (a summary's only children here are its badge/links, never a nested section — that sits
      # beside it, inside the same <details> — so a block-scoped assert_select on the summary
      # itself cannot see a child section; this walks the DOM directly instead.
      docs_section = css_select(".file-tree-section").find { |el| el.at_css("> details > summary")&.text.to_s =~ /docs \(1\)/ }
      assert docs_section, "expected to find the docs section"
      assert_match(/wiring \(1\)/, docs_section.at_css(".file-tree-section details summary")&.text.to_s,
                   "docs must nest wiring")
      assert_select ".attachment-tile .grid-name", text: "bracket.stl"
      assert_select ".attachment-tile .grid-name", text: "manual.pdf"
      assert_select ".attachment-tile .grid-name", text: "pinout.pdf"
    end

    test "an empty subfolder still renders its own section, with no files" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      subfolder!(user, project, name: "empty")

      get project_path(project)
      assert_response :success
      assert_select ".file-tree-section details summary", text: /empty \(0\)/
      assert_select "p.muted", text: /No files in this project yet/, count: 0
    end

    test "a repository inside the folder is a nested section, badged, linking to its commit and history pages, with its files inside it" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project.ensure_library_folder!(user)
      firmware = user.nodes.create!(node_id: "d-firmware", name: "firmware", kind: "dir",
                                    parent_node_id: folder.node_id)
      user.nodes.create!(node_id: "d-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                         parent_node_id: firmware.node_id)
      folder_file!(user, project, name: "main.c", node_id: "n-mainc", parent: firmware.node_id)

      get project_path(project)
      assert_response :success
      assert_select ".file-tree-section details summary", text: /firmware/ do
        assert_select "span.badge", text: "repo"
        assert_select "a[href=?]", repo_commit_path(firmware.node_id)
        assert_select "a[href=?]", repo_history_path(firmware.node_id)
      end
      assert_select ".attachment-tile .grid-name", text: "main.c"
      # No standalone Repositories group any more — a repo is a section now.
      assert_select ".attachment-group-head", text: /Repositories/, count: 0
    end

    test "folder files do not get Detach" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      attach_folder_node(user, project, name: "bracket.stl", node_id: "n-bracket", role: "model")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-tile", 1
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
      assert_select ".attachment-tile", Maker::ProjectFolderListing::FILE_CAP
      # `text:` on the LINK selector below checks the link's own text ("Open the folder"), not the
      # paragraph's — the count sentence is asserted on the paragraph itself.
      assert_select ".attachments-truncated", text: /Showing 300 of 301/
      assert_select ".attachments-truncated a[href=?]", files_path(folder: folder.node_id),
                    text: "Open the folder"
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

    test "a file attached from elsewhere is Linked, with Detach and Move into project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      attach_node(user, project, name: "loose.stl", node_id: "n-loose", role: "model")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-group-head", text: /Linked from elsewhere \(1\)/
      assert_select ".attachment-tile button.tile-detach"
      assert_select ".attachment-tile form[action=?] button.tile-move",
                    relocate_project_attachments_path(project)
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

    # Native <details>, so this works with no JavaScript at all. `open` on an ordinary subfolder
    # section is what keeps the panel readable by default — Backups is the one group that starts
    # closed (see below).
    test "a real subfolder's section is a collapsible details, open by default" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      models = subfolder!(user, project, name: "models")
      folder_file!(user, project, name: "arm.stl", node_id: "n-arm", parent: models.node_id)

      get project_path(project)
      assert_select ".file-tree-section details[open] summary", text: /models \(1\)/
    end

    # LightBurn and MillMage drop a `<stem>_backup.<ext>` rescue copy beside every project file, so
    # a laser-heavy project's panel was half rescue copies of the design next to it. They move to
    # their own CLOSED section rather than being dropped: the file is really in the project's
    # folder, and a panel that hid it would be lying about what is on disk.
    test "LightBurn backups move to a collapsed Backups section, out of their own subfolder" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      laser = subfolder!(user, project, name: "laser")
      # Backup detection (Row#backup?) reads the node's own name, wherever it sits in the tree.
      folder_file!(user, project, name: "sign.lbrn2", node_id: "n-sign", parent: laser.node_id)
      folder_file!(user, project, name: "sign_backup.lbrn2", node_id: "n-bak", parent: laser.node_id)

      get project_path(project)
      assert_select ".file-tree-section details summary", text: /laser \(1\)/
      assert_select ".attachment-group-head", text: /Backups \(1\)/
      # CLOSED, which is the whole of "don't show the backups" — one click away, not gone (its
      # tile is still IN the markup, same as any other <details> content, just not the default
      # open state — assert_select sees it either way).
      assert_select ".attachment-group details:not([open]) summary", text: /Backups/
      assert_select ".file-tree-section details[open] summary", text: /laser/
      # THE FILE ITSELF RENDERS EXACTLY ONCE, and NOT inside the laser section it physically sits
      # in -- Backups pulls it out rather than duplicating it.
      assert_select ".attachment-tile .grid-name", text: "sign_backup.lbrn2", count: 1
      laser_section = css_select(".file-tree-section").find { |el| el.at_css("> details > summary")&.text.to_s =~ /laser/ }
      assert_no_match(/sign_backup\.lbrn2/, laser_section.text, "the backup must not also render inside laser")
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
      assert_select ".loose-note", text: /Loose files are filed on the next sweep/
      # ONE tile, ONE file counted -- the pointer is not a second, merely-hidden row.
      assert_select ".attachment-tile", 1
      assert_select ".attachment-group-head", text: /Loose \(1\)/
    end

    # --- the list view (stage 3, S3-1) ------------------------------------------

    test "the list view renders a table with Section and Origin cells and the choice is remembered" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      models = subfolder!(user, project, name: "models")
      folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket", parent: models.node_id)

      get project_path(project, view: "list")
      assert_response :success
      assert_select "table.table.project-files"
      assert_select "table.project-files td.col-section", text: "models"
      assert_select "table.project-files td.col-origin", text: "—"
      assert_select ".view-toggle a.toggle.active", text: "List"

      # The cookie remembers list across a bare request with no ?view= at all.
      get project_path(project)
      assert_select "table.table.project-files"
    end

    test "tiles is the default view, and an explicit ?view=tiles switches back" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket")

      get project_path(project)
      assert_select ".view-toggle a.toggle.active", text: "Tiles"
      assert_select ".attachments-grid .attachment-tile"

      get project_path(project, view: "list")
      get project_path(project, view: "tiles")
      assert_select ".view-toggle a.toggle.active", text: "Tiles"
      assert_select "table.project-files", count: 0
    end

    # --- Generated (stage 3, S3-1) ----------------------------------------------

    # THE FIXTURE IDIOM FROM addon_origin_surfaces_test.rb: a Maker::AddonState + AddonFile tie a
    # node to a saved addon "thing". Revision 3, not the default 1, so the "rev N" assertion cannot
    # pass against a hardcoded number.
    test "a generated file appears once in Generated, with its tool, item and revision, and never in its section" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      models = subfolder!(user, project, name: "models")
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
      assert_select ".generated-group .attachment-group-head", text: /Generated \(1\)/
      assert_select ".generated-group .grid-name", text: "box.svg"
      assert_select ".generated-group .generated-meta", text: /shelf box/
      assert_select ".generated-group .generated-meta", text: /rev 3/
      assert_select ".generated-group a", text: "Edit in Box Generator"
      # NOT repeated inside its own section.
      assert_select ".file-tree-section details summary", text: /models \(0\)/

      # THE LIST VIEW'S ORIGIN COLUMN IS THE TOOL'S TITLE, read from the origin hash's own key —
      # not a prefix stripped off the menu label, which a rewording would silently break (review).
      get project_path(project, view: "list")
      assert_select ".generated-group td.col-origin", text: "Box Generator"
    ensure
      Maker::Addons::Source.reset!
    end
  end
end
