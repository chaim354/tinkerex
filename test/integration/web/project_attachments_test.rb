require "test_helper"

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
    # SITS AT THE LIBRARY ROOT — outside any project's folder — which stage 2's folder-based panel
    # (Maker::ProjectFolderListing) makes the LINKED CASE: attached to this project, but not one of
    # its folder's own files. Kept under its original name because most of the tests below only
    # care that an attached, live file renders as a tile — which a Linked row still does.
    def attach_node(user, project, name:, node_id:, role: "model")
      user.nodes.create!(node_id:, name:, kind: "file")
      project.file_attachments.create!(user:, node_id:, role:)
    end

    # A node placed INSIDE a folder — the project's own root, or a subfolder created separately
    # with kind: "dir" and passed as `parent`. This is what Maker::ProjectFolderListing walks, so a
    # test about role-heading grouping, Backups, or Repositories needs its fixtures here rather
    # than at attach_node's library root. Ensures the project's folder once; the ensure is
    # idempotent (Maker::Project#ensure_library_folder!), so calling it once per fixture in a test
    # with several is harmless.
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

    # --- the folder is the panel (stage 2, S2-2) ---------------------------------

    # "grouped by role from the filename" is the headline, and NO row here has an attachment at
    # all except bracket.stl — the point being that a folder file is listed on the strength of
    # being in the folder, with or without a maker_file_attachments row.
    test "the panel lists the folder, grouped by role from the filename, whether or not a row exists" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder = project.ensure_library_folder!(user)
      models = user.nodes.create!(node_id: "d-models", name: "models", kind: "dir",
                                  parent_node_id: folder.node_id)
      images = user.nodes.create!(node_id: "d-images", name: "images", kind: "dir",
                                  parent_node_id: folder.node_id)
      folder_file!(user, project, name: "bracket.stl", node_id: "n-bracket", parent: folder.node_id)
      project.file_attachments.create!(user:, node_id: "n-bracket", role: "model")
      folder_file!(user, project, name: "shade.stl", node_id: "n-shade", parent: models.node_id)
      folder_file!(user, project, name: "photo.jpg", node_id: "n-photo", parent: images.node_id)

      get project_path(project)
      assert_response :success
      assert_select ".attachment-group-head", text: /Models \(2\)/
      assert_select ".attachment-group-head", text: /Images \(1\)/
      assert_select ".attachment-tile", 3
      assert_select ".attachment-group-head", text: /Linked/, count: 0
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

    test "a repository inside the folder is one entry and its files are not tiles" do
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
      assert_select ".attachment-group-head", text: /Repositories \(1\)/
      assert_select ".repo-tile a[href=?]", files_path(folder: firmware.node_id)
      assert_select ".attachment-tile .grid-name", text: "main.c", count: 0
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

    # A GENUINELY EMPTY PROJECT (no folder files, no linked attachments, no repos, nothing
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

    test "the files panel groups attachments by type and omits empty categories" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      # FOUR NODES INSIDE THE FOLDER, not at the library root as before folder-based listing:
      # role-heading grouping (Models, Images, Vector, …) now comes from
      # Maker::ProjectFolderListing, which only sees files inside the project's folder — a
      # root-level attachment renders in Linked instead (see the Linked-case tests above).
      attach_folder_node(user, project, name: "bracket.stl", node_id: "n-1", role: "model")
      attach_folder_node(user, project, name: "shade.stl",   node_id: "n-2", role: "model")
      attach_folder_node(user, project, name: "photo.jpg",   node_id: "n-3", role: "image")
      attach_folder_node(user, project, name: "panel.dxf",   node_id: "n-4", role: "vector")

      get project_path(project)
      assert_response :success

      # One section per non-empty role, in ROLE_LABELS order.
      assert_select ".attachment-group", count: 3
      assert_select ".attachment-group-head", text: /Models/
      assert_select ".attachment-group-head", text: /Images/
      assert_select ".attachment-group-head", text: /Vector/
      # Empty categories are not rendered at all.
      assert_select ".attachment-group-head", text: /G-code/, count: 0
      assert_select ".attachment-group-head", text: /Archives/, count: 0

      # Headings carry the count, and the per-tile role badge is gone.
      assert_select ".attachment-group-head", text: /Models \(2\)/
      assert_select ".attachment-tile .badge", count: 0
    end

    # THE COUNTS COUNT WHAT IS SHOWN. A gone attachment used to render in its category and be
    # tallied there, so "Models (3)" could mean two files and a ghost — a heading contradicting the
    # tiles beneath it.
    test "a gone attachment is not counted in its category heading either" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # arm.stl has to live INSIDE the folder for "Models (1)" to be the heading it renders under
      # — a root-level attachment renders in Linked instead (see above).
      attach_folder_node(user, project, name: "arm.stl", node_id: "n-arm", role: "model")
      project.file_attachments.create!(user:, node_id: "vanished", role: "model",
                                       label: "bracket.stl")

      get project_path(project)
      assert_select ".attachment-group-head", text: /Models \(1\)/
      assert_select ".attachment-tile .grid-name", text: "arm.stl"
      assert_no_match(/bracket\.stl/, response.body)
    end

    # --- collapsible sections + LightBurn/MillMage backups ----------------------

    # Native <details>, so this works with no JavaScript at all. `open` on the ordinary groups is
    # what keeps the panel's default behaviour identical to before it became collapsible.
    test "each role section is a collapsible details, open by default" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # A plain folder file, no attachment at all — the folder is the relation a role section
      # shows, per docs/invariants/project-intake.md.
      folder_file!(user, project, name: "arm.stl", node_id: "n-arm")

      get project_path(project)
      assert_select ".attachment-group details[open] summary.attachment-group-head", text: /Models \(1\)/
    end

    # LightBurn and MillMage drop a `<stem>_backup.<ext>` rescue copy beside every project file, so
    # a laser-heavy project's panel was half rescue copies of the design next to it. They move to
    # their own CLOSED section rather than being dropped: the file is really in the project's
    # folder, and a panel that hid it would be lying about what is on disk.
    test "LightBurn backups move to a collapsed Backups section, out of Laser" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # Backup detection (Row#backup?) reads @listing.files, so both fixtures have to be inside
      # the folder — a Linked row renders in its own section regardless of extension.
      folder_file!(user, project, name: "sign.lbrn2", node_id: "n-sign")
      folder_file!(user, project, name: "sign_backup.lbrn2", node_id: "n-bak")

      get project_path(project)
      assert_select ".attachment-group-head", text: /Laser \(1\)/
      assert_select ".attachment-group-head", text: /Backups \(1\)/
      # CLOSED, which is the whole of "don't show the backups" — one click away, not gone.
      assert_select ".attachment-group details:not([open]) summary", text: /Backups/
      assert_select ".attachment-group details[open] summary", text: /Laser/
    end

    # THE NARROWNESS IS THE POINT. A user's own `battery_backup.stl` is not a LightBurn rescue copy,
    # and filing it as one would hide a real design file behind a collapsed section. Both halves of
    # the rule (the suffix AND the extension) have to hold.
    test "a file merely named _backup in another format is not treated as a backup" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder_file!(user, project, name: "battery_backup.stl", node_id: "n-bat")

      get project_path(project)
      assert_select ".attachment-group-head", text: /Models \(1\)/
      assert_select ".attachment-group-head", text: /Backups/, count: 0
    end

    # WAS: "an attachment with an off-vocabulary role still renders, under Other" — it set a
    # STORED role column to a bogus value with update_column, bypassing validation, because
    # role_for is total and nothing else could produce one. Row#role no longer reads that column
    # at all (Maker::FileAttachment.role_for(node.name), always — see
    # docs/invariants/project-intake.md), and a folder row carries no attachment to corrupt in the
    # first place (Row#attachment is nil), so that hazard is gone by construction, not merely
    # untested. What is left worth pinning is the ROLE_LABELS.key?(role) ? role : "other" fallback
    # in _attachments.html.erb still routing an unrecognized EXTENSION under Other — the same
    # visible behaviour, reached the way the new design actually reaches it.
    test "a file with an unrecognized extension still renders, under Other" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder_file!(user, project, name: "mystery.xyz", node_id: "n-x")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-group-head", text: /Other \(1\)/
      assert_select ".attachment-tile .grid-name", text: "mystery.xyz"
    end

    # THE COMPLAINT THIS ITEM STARTED FROM, asserted on both surfaces at once: a .csv is filed under
    # "Documents" in the project panel AND the Files page offers a chip in a family of that same
    # name. Before this the two pages named overlapping files differently, and .csv had no role at
    # all. This fails if either surface drifts, which is what "one vocabulary" has to mean.
    test "a document is filed under Documents and the chips agree" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      folder_file!(user, project, name: "cutlist.csv", node_id: "n-doc")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-group-head", text: /Documents/

      assert_includes FilesHelper::EXT_FAMILIES.keys, "Documents"
      assert_includes FilesHelper::EXT_FAMILIES["Documents"], "csv"
    end
  end
end
