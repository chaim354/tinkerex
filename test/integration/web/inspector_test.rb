require "test_helper"

module Web
  # THE INSPECTOR (structural redesign spec §5.2, slice 3): GET /files/:id/inspector, the Library's
  # right-hand panel for one selected file, built from the file page's own partials.
  #
  # PINNED TO A FRESH SHARE LIBRARY for the reason addon_origin_surfaces_test.rb gives: these tests
  # are about the web layer, and on the ambient s3 or chunk_remote leg a bare row would reach real
  # Aws calls or a live sync server. The two attach tests that MOVE a file need bytes on disk, so
  # they build their fixtures with create_node! (test_helper) rather than a bare nodes.create!.
  class InspectorTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "insp-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @dir = @user.nodes.create!(node_id: "dir-legs", name: "legs", kind: "dir", mtime: 1, size: 0)
      @file = @user.nodes.create!(node_id: "n-leg", name: "leg.lbrn2", kind: "file", mtime: 1, size: 5,
                                  parent_node_id: @dir.node_id)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "the inspector is one file's panel: name, Open, Download, facts, projects, notes" do
      project = @user.maker_projects.create!(name: "Shop Stool")
      @user.maker_notes.create!(node_id: @file.node_id, body: "Cut at 80%.")

      get inspector_file_path(@file.node_id)
      assert_response :success
      assert_select "turbo-frame#inspector[target='_top']" do
        assert_select ".inspector-name", text: "leg.lbrn2"
        assert_select "a[href=?]", file_path(@file.node_id), text: "Open"
        assert_select "a[href=?]", blob_file_path(@file.node_id, download: 1), text: "Download"
        assert_select "dl.meta dt", text: "Size"
        assert_select "form.attach-form input[name='return_to'][value='library']"
        assert_select "form.attach-form select option", text: project.name
        assert_select "a[href=?]", file_path(@file.node_id, anchor: "notes"), text: "1 note"
      end
      assert_select "aside.rail", { count: 0 }, "a frame body renders without the layout"
    end

    # THE GONE FRAME IS NOT IN template_hygiene_test.rb's `pages` SWEEP, because it answers 404 and
    # that sweep asserts :success on every page. Its rendered output is checked HERE instead, the
    # standing check that file's UNSWEPT_TEMPLATES entry names.
    test "a folder, a tombstone or another user's file answers a gone frame, not a page" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      theirs = other.nodes.create!(node_id: "n-theirs", name: "x.stl", kind: "file", mtime: 1, size: 1)
      gone = @user.nodes.create!(node_id: "n-gone", name: "old.stl", kind: "file", mtime: 1, size: 1,
                                 deleted: true)
      [ @dir.node_id, gone.node_id, theirs.node_id, "no-such-node" ].each do |id|
        get inspector_file_path(id)
        assert_response :not_found
        assert_select "turbo-frame#inspector", text: /isn't here any more/
        assert_select "aside.rail", { count: 0 }, "the gone frame renders without the layout"
        assert_not_includes response.body, "<%", "the gone frame leaked an ERB opener"
        assert_not_includes response.body, "%>", "the gone frame leaked an ERB closer"
      end
    end

    # THE PORT'S NotFound — a node tombstoned between the lookup and the `stat` — is the same gone
    # frame. Without the action's own rescue the class-level rescue_from answers a 302 to
    # files_path, which a frame would follow and put the whole Library into the panel. The fake is
    # the house way (attach_auto_move_test.rb's with_broken_move): an object answering only what the
    # code under test calls.
    test "a node the port no longer finds answers the gone frame, not the controller's redirect" do
      vanished = Object.new
      vanished.define_singleton_method(:stat) { |*, **| raise FileLayer::NotFound, "gone mid-request" }
      FileLayer.current = vanished

      get inspector_file_path(@file.node_id)
      assert_response :not_found
      assert_select "turbo-frame#inspector", text: /isn't here any more/
    end

    # THE PANEL OPENS ON EVERY SELECTION, SO IT MUST ASK FOR THE EXISTING ROW BEFORE IT ENQUEUES
    # (files-preview.md: `Enqueue.call` resets a `failed` row to `pending` and re-enqueues on every
    # call). A `failed` row is the ONE state where the two spellings differ — `call` returns a
    # current `ready` or `pending` row untouched too — so it is the fixture. And the assertion is on
    # the row's status and the job queue, never on a row count: the table's key is one row per
    # (node, kind), so a count cannot exceed 1 whatever this door does.
    test "a failed render stays failed: opening the panel twice never re-enqueues it" do
      @file.update_columns(content_hash: "h-leg")
      row = @user.maker_previews.create!(
        node_id: @file.node_id, kind: "thumbnail", version_id: "h-leg", status: "failed",
        error: "render failed",
        renderer_revision: Maker::Previews::Enqueue.revision_for_name(@file.name, "thumbnail")
      )

      assert_no_enqueued_jobs(only: Maker::GeneratePreviewJob) do
        2.times do
          get inspector_file_path(@file.node_id)
          assert_response :success
        end
      end
      assert_equal "failed", row.reload.status
      assert_select ".inspector-stage .thumb-icon", { count: 1 },
                    "precondition: the panel rendered the failed row's badge, so it read the row"
    end

    test "attaching from the inspector lands back in the Library with the file selected" do
      project = @user.maker_projects.create!(name: "Shop Stool")
      post attachments_path, params: { node_id: @file.node_id, project_id: project.slug,
                                       return_to: "library" }
      assert_redirected_to files_path(folder: @dir.node_id, selected: @file.node_id)
    end

    # A FIRST ATTACH MOVES THE FILE INTO THE PROJECT'S FOLDER (Maker::AttachToProject), so "the
    # file's folder" is the one it is in AFTER the move — Maker::MoveNode reloads the node it was
    # handed. Landing in the folder it left would select a file that listing no longer holds.
    test "an attach that moves the file lands in the folder it moved to, still selected" do
      project = @user.maker_projects.create!(name: "Shop Stool")
      create_node!(@user, node_id: "n-real", name: "seat.lbrn2", kind: "file", mtime: 1, size: 1)

      post attachments_path, params: { node_id: "n-real", project_id: project.slug,
                                       return_to: "library" }
      folder = @user.nodes.present.find_by!(name: project.slug, kind: "dir")
      assert_equal folder.node_id, @user.nodes.find_by!(node_id: "n-real").parent_node_id,
                   "precondition: the attach really moved the file"
      assert_redirected_to files_path(folder: folder.node_id, selected: "n-real")
    end

    # A MOVE CONFLICT'S PROMPT (projects/_move_conflict) RENDERS ON THE FILE PAGE AND THE PROJECT
    # PAGE, NEVER THE LIBRARY, so a colliding attach from the inspector falls back to the file page
    # rather than dropping the prompt. Fixture: attach_auto_move_test.rb's seed_collision, built the
    # same way.
    test "an attach from the inspector that collides falls back to the file page's prompt" do
      project = @user.maker_projects.create!(name: "Shop Stool")
      create_node!(@user, node_id: "n-real", name: "seat.lbrn2", kind: "file", mtime: 1, size: 1)
      folder = project.ensure_library_folder!(@user)
      create_node!(@user, node_id: "n-taken", name: "seat.lbrn2", kind: "file", mtime: 1, size: 1,
                          parent_node_id: folder.node_id)

      post attachments_path, params: { node_id: "n-real", project_id: project.slug,
                                       return_to: "library" }
      att = project.file_attachments.sole
      assert_redirected_to file_path("n-real", move_conflict: att.id)
      follow_redirect!
      assert_select "dialog.move-conflict", 1
    end

    # A NODE THAT VANISHED BEFORE THE ATTACH: back to the Library, never the project's picker —
    # the inspector was opened from the Library, and that page always renders.
    test "a not-found attach from the inspector returns to the Library" do
      project = @user.maker_projects.create!(name: "Shop Stool")
      post attachments_path, params: { node_id: "gone", project_id: project.slug,
                                       return_to: "library" }
      assert_redirected_to files_path
      assert_match(/isn't in your library/i, flash[:alert])
    end
  end
end
