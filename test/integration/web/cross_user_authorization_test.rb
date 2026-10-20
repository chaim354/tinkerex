require "test_helper"

module Web
  # ONE case per mutating web action, driven as a user who does not own the record.
  #
  # WHY A DEDICATED FILE RATHER THAN A CASE PER EXISTING FILE: the property is uniform — every web
  # controller scopes through `current_user.*` — so the tests are uniform, and gathering them makes
  # a MISSING one visible. Scattered across thirty files, "which actions are pinned?" is
  # unanswerable without reading all thirty. Before this file, 8 of ~30 web test files asserted it.
  #
  # EVERY CASE HERE PASSES ON THE FIRST RUN. That is expected and is the point: the property
  # already holds and almost nothing pinned it, so swapping `current_user.maker_projects.find` for
  # `Maker::Project.find` would have gone green across the whole suite. Mutation-checked on
  # projects, sheets and models — dropping `current_user` from each lookup turns the matching case
  # red.
  #
  # WHAT IS DELIBERATELY NOT ASSERTED: the exact status. 404 / redirect / 4xx is each controller's
  # own business, and pinning a specific code would make this file fail on an unrelated copy or
  # flow change. What is asserted is that the request is NOT successful and NOTHING moved.
  class CrossUserAuthorizationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # The victim owns everything.
      @owner = User.create!(email: "victim@example.com", password: PASSWORD,
                            confirmed_at: Time.current)
      @project = @owner.maker_projects.create!(name: "Theirs", status: "active")
      @task = @project.tasks.create!(user: @owner, title: "their task")
      @entry = @project.build_log_entries.create!(user: @owner, body: "their log",
                                                  logged_at: Time.current)
      @sheet = @project.sheets.create!(user: @owner, name: "their sheet")
      @model = @owner.maker_models.create!(title: "Their Model", slug: "their-model")
      @node = @owner.nodes.create!(node_id: "theirfile", name: "theirs.stl", kind: "file",
                                   size: 1, mtime: 1_700_000_000_000_000_000)
      @attachment = @project.file_attachments.create!(user: @owner, node_id: "theirfile",
                                                      role: "model")
      @model_attachment = @model.file_attachments.create!(user: @owner, node_id: "theirfile",
                                                          role: "model")
      @run = @model.print_runs.create!(user: @owner, printed_on: Date.current,
                                       outcome: "success")
      @note = @owner.maker_notes.create!(node_id: "theirfile", body: "their note")
      @trashed = @owner.nodes.create!(node_id: "theirtrash", name: "trashed.stl", kind: "file",
                                      size: 1, mtime: 1_700_000_000_000_000_000, deleted: true)

      # The intruder is signed in for every test below, and owns one file of their own so the
      # "attach MY file to THEIR project" case is about authorization and not about a missing node.
      @intruder = User.create!(email: "intruder@example.com", password: PASSWORD,
                              confirmed_at: Time.current)
      @intruder.nodes.create!(node_id: "mine", name: "mine.stl", kind: "file", size: 1,
                             mtime: 1_700_000_000_000_000_000)
      # VERIFIED at the helper, not merely posted: an anonymous session would make EVERY case below
      # pass for the wrong reason -- `assert_denied`/`assert_unreadable` only ask that the response
      # was not successful, which a redirect to the sign-in page satisfies while proving nothing
      # about scoping.
      sign_in_web!(@intruder, password: PASSWORD)
    end

    # A request that must not succeed and must not change anything.
    def assert_denied(counted, &request)
      assert_no_difference(counted) { request.call }
      assert_not response.successful?,
                 "a non-owner got #{response.status} — the record was not scoped to the user"
    end

    def assert_unreadable(path)
      get path
      assert_not response.successful?,
                 "a non-owner read #{path} and got #{response.status}"
    end

    # --- projects --------------------------------------------------------------

    test "cannot view another user's project" do
      assert_unreadable project_path(@project)
    end

    test "cannot edit another user's project" do
      assert_unreadable edit_project_path(@project)
    end

    test "cannot update another user's project" do
      patch project_path(@project), params: { project: { name: "Stolen" } }
      assert_not response.successful?
      assert_equal "Theirs", @project.reload.name
    end

    test "cannot destroy another user's project" do
      assert_denied("Maker::Project.count") { delete project_path(@project) }
    end

    test "cannot unarchive another user's project" do
      @project.update!(status: "archived")
      patch unarchive_project_path(@project)
      assert_not response.successful?
      assert_equal "archived", @project.reload.status
    end

    # --- tasks -----------------------------------------------------------------

    test "cannot add a task to another user's project" do
      assert_denied("Maker::Task.count") do
        post project_tasks_path(@project), params: { task: { title: "injected" } }
      end
    end

    test "cannot update another user's task" do
      patch task_path(@task), params: { task: { title: "changed" } }
      assert_not response.successful?
      assert_equal "their task", @task.reload.title
    end

    test "cannot destroy another user's task" do
      assert_denied("Maker::Task.count") { delete task_path(@task) }
    end

    # --- build log -------------------------------------------------------------

    test "cannot add a build-log entry to another user's project" do
      assert_denied("Maker::BuildLogEntry.count") do
        post project_build_log_entries_path(@project),
             params: { build_log_entry: { body: "injected" } }
      end
    end

    test "cannot destroy another user's build-log entry" do
      assert_denied("Maker::BuildLogEntry.count") { delete build_log_entry_path(@entry) }
    end

    test "cannot attach a photo to another user's build-log entry" do
      assert_denied("Maker::FileAttachment.count") do
        post entry_photos_path(@entry), params: { node_id: "mine" }
      end
    end

    # --- sheets ----------------------------------------------------------------

    test "cannot read another user's sheet" do
      assert_unreadable sheet_path(@sheet)
    end

    test "cannot update another user's sheet" do
      patch sheet_path(@sheet), params: { sheet: { name: "stolen" } }
      assert_not response.successful?
      assert_equal "their sheet", @sheet.reload.name
    end

    test "cannot destroy another user's sheet" do
      assert_denied("Maker::Sheet.count") { delete sheet_path(@sheet) }
    end

    test "cannot create a sheet on another user's project" do
      assert_denied("Maker::Sheet.count") do
        post project_sheets_path(@project), params: { sheet: { name: "injected" } }
      end
    end

    # --- project attachments ---------------------------------------------------

    test "cannot attach my own file to another user's project" do
      assert_denied("Maker::FileAttachment.count") do
        post project_attachments_path(@project), params: { node_id: "mine" }
      end
    end

    test "cannot detach another user's attachment" do
      assert_denied("Maker::FileAttachment.count") { delete attachment_path(@attachment) }
    end

    test "cannot open the attach picker for another user's project" do
      assert_unreadable new_project_attachment_path(@project)
    end

    # --- models ----------------------------------------------------------------

    test "cannot view another user's model" do
      assert_unreadable model_path(@model)
    end

    test "cannot edit another user's model" do
      assert_unreadable edit_model_path(@model)
    end

    test "cannot update another user's model" do
      patch model_path(@model), params: { model: { title: "Stolen" } }
      assert_not response.successful?
      assert_equal "Their Model", @model.reload.title
    end

    test "cannot destroy another user's model" do
      assert_denied("Maker::Model.count") { delete model_path(@model) }
    end

    test "cannot attach a file to another user's model" do
      assert_denied("Maker::FileAttachment.count") do
        post model_attachments_path(@model), params: { node_id: "mine" }
      end
    end

    test "cannot detach another user's model attachment" do
      # Nested route — /models/:model_id/attachments/:id — unlike the project side's flat
      # /attachments/:id. The controller resolves the model first, so this exercises the outer
      # scope as well as the inner one.
      assert_denied("Maker::FileAttachment.count") do
        delete model_attachment_path(@model, @model_attachment)
      end
    end

    test "cannot log a print run on another user's model" do
      assert_denied("Maker::PrintRun.count") do
        post model_print_runs_path(@model),
             params: { print_run: { printed_on: Date.current, outcome: "success" } }
      end
    end

    test "cannot destroy another user's print run" do
      assert_denied("Maker::PrintRun.count") { delete print_run_path(@run) }
    end

    # --- files -----------------------------------------------------------------

    test "cannot read another user's file metadata" do
      assert_unreadable file_path(@node.node_id)
    end

    test "cannot download another user's bytes" do
      assert_unreadable blob_file_path(@node.node_id)
    end

    test "cannot delete another user's file" do
      assert_denied("Node.where(deleted: false).count") { delete file_path(@node.node_id) }
    end

    test "cannot restore another user's trashed file" do
      # A tombstone is still the owner's data — restoring it into the intruder's library would be
      # a cross-tenant read dressed as an undelete.
      post restore_trash_path(@trashed.node_id)
      assert_not response.successful?
      assert @trashed.reload.deleted?, "another user's file must stay in the trash"
    end

    # --- notes -----------------------------------------------------------------

    test "cannot destroy another user's note" do
      assert_denied("Maker::Note.count") { delete note_path(@note) }
    end

    test "cannot add a note to another user's file" do
      assert_denied("Maker::Note.count") do
        post file_notes_path(@node.node_id), params: { body: "injected" }
      end
    end
  end
end
