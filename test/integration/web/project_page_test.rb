require "test_helper"

module Web
  # The project page after PR 3 (spec §8): a stats line from what the page already loads, real
  # buttons in the head, Detach as a corner control on smaller tiles, task rows with a state mark
  # and the composer BELOW the list, a build-log composer that opens on demand, and a timeline with
  # the date in its own column. Nothing here adds a query: page_query_budget_test.rb still holds.
  class ProjectPageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "pp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp", description: "An articulated lamp.")
      # BOTH FILES LIVE IN THE PROJECT'S FOLDER, not at the library root: the stats line's file
      # count is now Maker::ProjectFolderListing#total (the folder), not maker_file_attachments —
      # an attachment to a node outside the folder is the Linked case, set up separately below so
      # it does not inflate this count.
      folder = project_folder_rows!(@user, @project)
      %w[base.stl shade.3mf].each_with_index do |name, i|
        @user.nodes.create!(node_id: "n-#{i}", name:, kind: "file", parent_node_id: folder.node_id,
                            mtime: 1_000_000_000, size: 10)
        @project.file_attachments.create!(user: @user, node_id: "n-#{i}", role: "model")
      end
      # THE LINKED CASE: attached to this project, but the node lives elsewhere in the library. It
      # is what "1 linked" below is about, and it is also the ONE attachment tile on this page that
      # carries Detach — a plain folder file has nothing to detach (the folder IS its relation).
      @user.nodes.create!(node_id: "n-linked", name: "spare.stl", kind: "file",
                          mtime: 1_000_000_000, size: 10)
      @linked_attachment = @project.file_attachments.create!(user: @user, node_id: "n-linked",
                                                              role: "model")
      @project.tasks.create!(user: @user, title: "Print the base", status: "done", position: 0)
      @project.tasks.create!(user: @user, title: "Wire the LED", status: "todo", position: 1)
      @project.tasks.create!(user: @user, title: "Design the clip", status: "todo", position: 2)
      @project.build_log_entries.create!(user: @user, entry_type: "note", logged_at: 2.days.ago,
                                        body: "<div>First print came out clean.</div>")
      @project.sheets.create!(user: @user, name: "Bill of materials")
    end

    test "the head shows a stats line built from what the page already loaded" do
      get project_path(@project)
      assert_response :success
      assert_select ".project-head .page-title h1", text: "Desk Lamp"
      assert_select ".project-stats", text: /2 files/
      assert_select ".project-stats", text: /1 linked/
      assert_select ".project-stats", text: /1 of 3 tasks done/
      assert_select ".project-stats", text: /1 log entry\b/
      assert_select ".project-stats", text: /1 sheet\b/
    end

    test "the head's actions are buttons, with Archive quiet and Set as current outlined" do
      get project_path(@project)
      assert_select ".head-actions form[action=?] button.btn.outline", current_project_path, text: /set as current/i
      assert_select ".head-actions a.btn[href=?]", edit_project_path(@project), text: "Edit"
      assert_select ".head-actions form[action=?] button.btn.danger", project_path(@project), text: "Archive"
    end

    # DETACH IS THE LINKED ROW'S CONTROL, ONLY. base.stl/shade.3mf are plain folder files now (no
    # tile-meta corner at all — folder_files_do_not_get_detach in project_attachments_test.rb pins
    # that directly); @linked_attachment is the one tile this page renders with a Detach button.
    test "attachment tiles carry Detach as a corner control that keeps its text" do
      get project_path(@project)
      assert_select ".attachments-panel .attachment-tile .tile-meta form[action=?] button.tile-detach",
                    attachment_path(@linked_attachment), text: "Detach"
    end

    test "task rows carry a state mark and the composer sits below the list" do
      get project_path(@project)
      assert_select "#project-tasks .tasks-group.status-done .task-row .task-state.task-state--done", count: 1
      assert_select "#project-tasks .tasks-group.status-todo .task-row .task-state.task-state--todo", count: 2
      children = css_select("#project-tasks > *").map { |el| el["class"].to_s }
      last_group = children.rindex { |c| c.include?("tasks-group") }
      form = children.index { |c| c.include?("task-form") }
      assert form && last_group && form > last_group, "the task form must come after the task groups, got #{children.inspect}"
      assert_select "#project-tasks form.task-form input[type='text'][name='task[title]']"
    end

    test "the build-log composer is a closed details holding the same form" do
      get project_path(@project)
      assert_select ".build-log-panel details.composer:not([open]) > summary", text: "Add entry"
      assert_select ".build-log-panel details.composer form[action=?] lexxy-editor[attachments='false']",
                    project_build_log_entries_path(@project)
      assert_select ".build-log-panel details.composer form input[type='submit'][value='Add entry']"
    end

    test "a log entry puts its date in the first column and its body in the second" do
      get project_path(@project)
      assert_select ".log-timeline .log-entry > time.entry-time", count: 1
      assert_select ".log-timeline .log-entry > .entry-main .entry-body", text: /First print came out clean/
      assert_select ".log-timeline .log-entry > .entry-main .entry-head form button", text: "Delete"
    end

    # --- tags (stage 2, S2-5) ----------------------------------------------------------------

    test "an untagged project shows no chip row" do
      get project_path(@project)
      assert_select ".tag-chips", 0
    end

    test "tag chips render on the project page and link to the tag page" do
      tagged = @user.maker_projects.create!(name: "Tagged Lamp", tag_list: "laser, firmware")
      get project_path(tagged)
      assert_select ".tag-chips a.tag-chip[href=?]", tag_path("firmware"), text: "firmware"
      assert_select ".tag-chips a.tag-chip[href=?]", tag_path("laser"), text: "laser"
    end

    test "the form carries a tag_list field" do
      get edit_project_path(@project)
      assert_select "input[name='project[tag_list]']"
    end

    test "update with tag_list writes two tags and the page renders their chips" do
      patch project_path(@project), params: { project: { name: @project.name, tag_list: "laser, firmware" } }
      assert_redirected_to project_path(@project)
      assert_equal %w[firmware laser], @project.reload.tag_list.split(", ").sort

      get project_path(@project)
      assert_select ".tag-chips a.tag-chip", 2
    end

    # THE NEGATIVE WEARS A DIFFERENT TAG, not none: an untagged row is excluded by the inner join
    # alone, so only a differently-tagged sibling proves the scope matches the NAME (review, S2-5).
    test "the index shows tag filter chips and ?tag= narrows, excluding a project wearing another tag" do
      tagged = @user.maker_projects.create!(name: "Laser Sign", tag_list: "laser")
      untagged = @user.maker_projects.create!(name: "Firmware Board", tag_list: "firmware")

      get projects_path
      assert_select ".projects-toolbar a.filter.chip", text: "laser"

      get projects_path(tag: "laser")
      assert_select "a.project-card[href=?]", project_path(tagged)
      assert_select "a.project-card[href=?]", project_path(untagged), false
    end

    test "a user with no project tags sees no filter toolbar" do
      get projects_path
      assert_select ".projects-toolbar", count: 0
    end

    # Ground rules for this task: ProjectsController#index also gained a `?q=` filter (one line,
    # the Files LOWER(name) LIKE ... ESCAPE idiom) so SearchController's "See all" link into
    # projects_path(q:) narrows -- Task B's own search_test.rb exercises that link end to end;
    # this is the controller-level check that the filter itself works in isolation.
    test "?q= narrows the index by name" do
      matched = @user.maker_projects.create!(name: "Desk Lamp Mk2")
      other = @user.maker_projects.create!(name: "Bare Shelf")

      get projects_path(q: "lamp")
      assert_select "a.project-card[href=?]", project_path(matched)
      assert_select "a.project-card[href=?]", project_path(other), false
    end
  end
end
