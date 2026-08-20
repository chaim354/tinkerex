require "test_helper"

module Web
  class ProjectAttachmentsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Sync::Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    # Seed a library node + attach it to a project via the model (attach UI is Task 6).
    def attach_node(user, project, name:, node_id:, role: "model")
      user.nodes.create!(node_id:, name:, kind: "file")
      project.file_attachments.create!(user:, node_id:, role:)
    end

    test "attached files render as tiles linking to the file view" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
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
      attach_node(user, project, name: "bracket.stl", node_id: "n-live", role: "model")
      project.file_attachments.create!(user:, node_id: "gone", role: "model", label: "ghost.stl")

      get project_path(project)
      assert_select ".attachments-missing", text: /1 attached file no longer in your library/
      assert_select ".attachments-missing a[href=?]", trash_index_path
      # The live one is untouched — this is a filter, not an outage.
      assert_select ".attachment-tile .grid-name", text: "bracket.stl"
    end

    # An "empty" project and a project whose files were all deleted are DIFFERENT SENTENCES. Saying
    # "No files attached yet" to someone who just deleted four is a lie about what happened.
    test "a project whose every file is gone explains itself instead of reading as empty" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.file_attachments.create!(user:, node_id: "gone", role: "model", label: "ghost.stl")

      get project_path(project)
      assert_select ".attachments-missing", text: /1 attached file no longer in your library/
      assert_select "p.muted", text: "No files attached yet.", count: 0
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

      attach_node(user, project, name: "bracket.stl", node_id: "n-1", role: "model")
      attach_node(user, project, name: "shade.stl",   node_id: "n-2", role: "model")
      attach_node(user, project, name: "photo.jpg",   node_id: "n-3", role: "image")
      attach_node(user, project, name: "panel.dxf",   node_id: "n-4", role: "vector")

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
      attach_node(user, project, name: "arm.stl", node_id: "n-arm", role: "model")
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
      attach_node(user, project, name: "arm.stl", node_id: "n-arm", role: "model")

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
      attach_node(user, project, name: "sign.lbrn2", node_id: "n-sign", role: "laser")
      attach_node(user, project, name: "sign_backup.lbrn2", node_id: "n-bak", role: "laser")

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
      attach_node(user, project, name: "battery_backup.stl", node_id: "n-bat", role: "model")

      get project_path(project)
      assert_select ".attachment-group-head", text: /Models \(1\)/
      assert_select ".attachment-group-head", text: /Backups/, count: 0
    end

    # The view iterates ROLE_LABELS, so a role outside that vocabulary would render nowhere at all —
    # a file silently missing from the user's own project. Nothing can write such a value today
    # (role_for is total, the model validates), so this has to bypass validation to set one up.
    test "an attachment with an off-vocabulary role still renders, under Other" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      att = attach_node(user, project, name: "mystery.xyz", node_id: "n-x", role: "other")
      att.update_column(:role, "bogus_role")

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
      attach_node(user, project, name: "cutlist.csv", node_id: "n-doc",
                  role: Maker::FileAttachment.role_for("cutlist.csv"))

      get project_path(project)
      assert_response :success
      assert_select ".attachment-group-head", text: /Documents/

      assert_includes FilesHelper::EXT_FAMILIES.keys, "Documents"
      assert_includes FilesHelper::EXT_FAMILIES["Documents"], "csv"
    end
  end
end
