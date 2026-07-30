require "test_helper"

module Maker
  # The intake policy, WITHOUT HTTP.
  #
  # PINNED TO CHUNK, like attach_to_project_test.rb, and for the same reason: the policy is
  # backend-neutral, but the move it drives is Maker::MoveNode's two-door branch and on share/s3
  # the port wants a real disk or bucket behind every fixture. The doors themselves are covered
  # per-backend in move_node_test.rb and library_folder_test.rb.
  class ProjectIntakeTest < ActiveSupport::TestCase
    setup do
      pin_file_layer_backend("chunk")
      @user = User.create!(email: "pi-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
    end

    # A live file node under `parent`, defaulting to the project folder's root (the inbox).
    def file(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                          parent_node_id: parent, size: 1, content_hash: SecureRandom.hex(8))
    end

    def dir(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent)
    end

    def intake = Maker::ProjectIntake.for_project(user: @user, project: @project)

    def roles = @project.file_attachments.pluck(:node_id, :role).to_h

    # --- the attach step ---------------------------------------------------------

    test "a file at the project folder root is attached" do
      node = file("bracket.stl")
      result = intake
      assert_equal 1, result.attached
      assert_equal "model", roles[node.node_id]
    end

    # THE HEADLINE CASE: dropped straight into a subfolder on the NAS, never at the root.
    test "a file nested in a subfolder is attached too" do
      sub = dir("design")
      node = file("panel.svg", parent: sub.node_id)
      assert_equal 1, intake.attached
      assert_equal "vector", roles[node.node_id]
    end

    test "a file two levels down is attached" do
      deep = dir("wip", parent: dir("design").node_id)
      node = file("draft.dxf", parent: deep.node_id)
      assert_equal 1, intake.attached
      assert_includes roles.keys, node.node_id
    end

    test "a file outside the project folder is not attached" do
      file("stray.stl", parent: nil)
      assert_equal 0, intake.attached
      assert_empty roles
    end

    test "a tombstoned file is not attached" do
      node = file("gone.stl")
      node.update!(deleted: true)
      assert_equal 0, intake.attached
    end

    test "directories are never attached" do
      dir("design")
      assert_equal 0, intake.attached
    end

    test "attaching is idempotent — a second run creates nothing" do
      file("bracket.stl")
      assert_equal 1, intake.attached
      assert_equal 0, intake.attached
      assert_equal 1, @project.file_attachments.count
    end

    # The row this service would have created already exists, made by the ordinary attach flow.
    test "a file already attached is not attached twice" do
      node = file("bracket.stl")
      @project.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      assert_equal 0, intake.attached
      assert_equal 1, @project.file_attachments.count
    end

    test "the role is derived per file, not copied" do
      stl = file("bracket.stl")
      pdf = file("guide.pdf")
      lbrn = file("box.lbrn2")
      intake
      assert_equal "model", roles[stl.node_id]
      assert_equal "instructions", roles[pdf.node_id]
      assert_equal "laser", roles[lbrn.node_id]
    end

    # --- the folder is READ, never ensured ---------------------------------------

    # THE SIDE-EFFECT BUG THIS DESIGN IS WRITTEN TO AVOID. Projects::AttachmentsController#relocate
    # shipped exactly this: an endpoint that created Projects/<slug> as a side effect of being
    # asked a question. A SWEEP doing it would create a folder for every project that never had one.
    test "a project with no folder is skipped and no folder is created" do
      bare = @user.maker_projects.create!(name: "Nothing Yet")
      before = @user.nodes.count
      result = Maker::ProjectIntake.for_project(user: @user, project: bare)
      assert_equal :no_folder, result.status
      assert_equal 0, result.attached
      assert_equal before, @user.nodes.count, "a sweep must not create the project's folder"
      assert_nil bare.reload.folder_node_id
    end

    test "a project whose folder was deleted is skipped, not recreated" do
      @folder.update!(deleted: true)
      before = @user.nodes.present.count
      assert_equal :no_folder, intake.status
      assert_equal before, @user.nodes.present.count
    end

    # An archived project's folder is still its folder. Skipping it would let files pile up in it
    # permanently unattached, silently.
    test "an archived project is still swept" do
      @project.archive!
      file("bracket.stl")
      assert_equal 1, intake.attached
    end

    # --- edge cases: a cycle, a symlink, dry-run, a folder_node_id that isn't a dir -------------

    # THE GUARD THIS EXERCISES. A literal "A and B are each other's parent" pair does NOT reach it:
    # each node has ONE parent_node_id, so closing that edge would disconnect the pair from @folder
    # and the walk would never enter it. Routing the cycle back through the PROJECT FOLDER ITSELF —
    # folder -> dir_a -> dir_b -> folder — is what actually re-presents an already-`seen` node_id to
    # the visited check. Without that check firing first, this would spin (MAX_DEPTH.times still
    # bounds the iteration count, but the visited set is what stops the file from being collected
    # more than once via repeated re-expansion — and maker_file_attachments has no uniqueness index,
    # so a double-collect would silently write two rows for one file).
    test "a cycle through the project folder terminates and attaches the file inside once" do
      dir_a = dir("dir_a")
      dir_b = dir("dir_b", parent: dir_a.node_id)
      @folder.update!(parent_node_id: dir_b.node_id)
      node = file("bracket.stl", parent: dir_a.node_id)

      result = intake
      assert_equal 1, result.attached
      assert_equal 1, @project.file_attachments.where(node_id: node.node_id).count
    end

    # `node.file?` / `elsif node.dir?` silently drops `kind: "symlink"` today — deliberately, per
    # subtree_files' comment. Pinned so a future `case node.kind` refactor that defaults to
    # "treat as file" regresses loudly instead of silently.
    test "a symlink is never attached" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "shortcut", kind: "symlink",
                          parent_node_id: @folder.node_id)
      assert_equal 0, intake.attached
    end

    # Live code, not scaffolding: Task 12's rake task depends on a preview that actually previews.
    test "dry_run reports the count but writes nothing" do
      file("bracket.stl")
      result = Maker::ProjectIntake.for_project(user: @user, project: @project, dry_run: true)
      assert_equal 1, result.attached
      assert_equal 0, @project.file_attachments.count
    end

    # live_folder's explicit `kind: "dir"` filter is what makes this :no_folder rather than a crash
    # or a false attach — the existing tombstone test exercises the `present` half of the same
    # find_by, not this one.
    test "a folder_node_id pointing at a file, not a dir, reads as no_folder" do
      stray = file("not-a-folder.stl", parent: nil)
      @project.update!(folder_node_id: stray.node_id)

      result = intake
      assert_equal :no_folder, result.status
      assert_equal 0, result.attached
    end

    # THE SILENT-TRUNCATION GAP. Without a warning, a legitimately deep (non-cyclic) tree past
    # MAX_DEPTH is indistinguishable from a complete sweep: `status` reads :ok either way. Builds a
    # chain of exactly MAX_DEPTH directories below the folder, so the file one level past that is
    # never reached (see MAX_DEPTH's comment for why) — and asserts on the LOGGED TEXT rather than
    # mocking Rails.logger, since Object#stub does not exist in this suite (minitest 6 dropped
    # minitest/mock). A real Logger writing into a StringIO needs no mock library.
    test "a tree deeper than MAX_DEPTH is truncated, logs a warning, and still reports :ok" do
      deepest = Maker::ProjectIntake::MAX_DEPTH.times.inject(@folder.node_id) do |parent, i|
        dir("level#{i}", parent:).node_id
      end
      buried = file("buried.stl", parent: deepest)

      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      result = begin
        intake
      ensure
        Rails.logger = original_logger
      end

      assert_equal :ok, result.status
      assert_equal 0, result.attached, "the file one level past MAX_DEPTH must not be found"
      assert_empty roles.slice(buried.node_id)
      assert_match @project.slug, log.string
      assert_match "1 directory left unvisited", log.string
    end
  end
end
