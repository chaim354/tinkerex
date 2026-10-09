require "test_helper"

module Web
  class ProjectTasksTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # The project detail view reads file metadata + capabilities through FileLayer.current; pin a
    # real backend so the share CI leg (no LIBRARY_PATH) doesn't fail on backend construction.
    setup do
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "add a task to a project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_difference "project.tasks.count", 1 do
        post project_tasks_path(project), params: { task: { title: "Print base" } }
      end
      task = project.tasks.last
      assert_equal "todo", task.status
      assert_redirected_to project_path(project)
    end

    # The two tests above/below POST `task: {...}` as a nested hash, which bypasses the form
    # entirely — it cannot see a malformed `name` attribute, so it stays green while the panel's
    # Add button is a hard 400. These two pin the WIRE FORMAT instead. Same shape as the PR #69
    # `scope:` gotcha, one view over.
    # WITHOUT JAVASCRIPT A REFUSED FIRST TASK RETURNS WITH ITS PANEL OPEN (Projects::PanelReturn): the
    # project has no tasks, so the plain page would carry no Tasks panel to show the refusal beside.
    test "a refused task without JavaScript returns to the opened Tasks panel" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_no_difference "project.tasks.count" do
        post project_tasks_path(project), params: { task: { title: "" } }
      end
      assert_redirected_to project_path(project, add: "tasks", anchor: "project-tasks")
      follow_redirect!
      assert_select "#project-tasks form.task-form"
    end

    test "the add-task field is named for the key the controller requires" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # ?add=tasks: an empty Tasks panel is absent until "+ Add panel" opens it (slice 6).
      get project_path(project, add: "tasks")
      assert_select "form.task-form input[type=text][name=?]", "task[title]"
    end

    test "submitting the add-task form as a browser does creates the task" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      get project_path(project, add: "tasks")

      # Scrape the form's OWN field name and submit that, urlencoded, so this test follows the
      # view rather than restating it — a name that stops matching the controller fails here.
      field = css_select("form.task-form input[type=text]").first
      assert field, "the add-task form should render a title field"

      assert_difference -> { project.tasks.count }, 1 do
        post project_tasks_path(project),
             params: "#{CGI.escape(field["name"])}=Print+base&commit=Add",
             headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
      end
      assert_redirected_to project_path(project)
      assert_equal "Print base", project.tasks.last.title
    end

    test "tasks render grouped by status" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.tasks.create!(user:, title: "A", status: "todo")
      project.tasks.create!(user:, title: "B", status: "done")
      get project_path(project)
      assert_select ".tasks-group.status-todo .task-title", text: "A"
      assert_select ".tasks-group.status-done .task-title", text: "B"
    end

    test "change a task's status" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "A", status: "todo")
      patch task_path(task), params: { task: { status: "done" } }
      assert_equal "done", task.reload.status
      assert task.completed_at.present?, "moving to done stamps completed_at"
    end

    test "delete a task" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "A")
      assert_difference "project.tasks.count", -1 do
        delete task_path(task)
      end
    end

    test "a task not scoped to a project is 404 here, never a 500" do
      user = sign_in
      task = user.maker_tasks.create!(title: "loose")   # taskable nil (optional) — not a project task
      patch task_path(task), params: { task: { status: "done" } }
      assert_response :not_found
    end

    test "moving a task out of done clears completed_at" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "A", status: "done", completed_at: Time.current)
      patch task_path(task), params: { task: { status: "todo" } }
      assert_nil task.reload.completed_at
    end

    # --- a REFUSED update must change nothing, and must say so ---------------------
    #
    # Both status tests above send a VALID status, so the write always succeeded and neither could
    # ever see the defect below — §14e's "a green suite over something that never worked". `#update`
    # decided whether to null completed_at from the PARAMS and wrote it with `update_column`, which
    # skips validation, so a refused write persisted `status="done", completed_at=NULL`: a pair no
    # sanctioned path can produce.
    test "a refused status change leaves status and completed_at consistent" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "A", status: "done", completed_at: Time.current)

      patch task_path(task), params: { task: { status: "bogus" } }

      task.reload
      assert_equal "done", task.status, "an invalid status must not be persisted"
      # A NIL/NON-NIL claim, deliberately — NOT "the stamp is unchanged" compared at `.to_i` (§15):
      # the request lands in the same whole second as the fixture, so that spelling would stay green
      # over exactly the write this pins.
      assert_not_nil task.completed_at, "a refused write must not null the stamp behind it"
    end

    # Silence was the other half: the action rendered the panel with no `alert:`, so the user pressed
    # a button, watched the panel redraw unchanged, and was told nothing — the same failure `create`
    # was already fixed for (the invalid-add test further down).
    test "a refused update reports itself inside the replaced panel" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "A", status: "done", completed_at: Time.current)

      patch task_path(task), params: { task: { status: "bogus" } }, as: :turbo_stream

      assert_select "turbo-stream[target=project-tasks]"
      assert_match(/task-error/, response.body)
    end

    # THE DONE BRANCH WAS NON-ATOMIC: `complete!` committed first and the second write could then
    # fail, leaving a task marked done still carrying the title the user was replacing. One
    # validated write makes the refusal total.
    test "a done transition the model refuses leaves the task not done" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "A", status: "todo")

      patch task_path(task), params: { task: { status: "done", title: "" } }

      task.reload
      assert_equal "todo", task.status, "a refused done transition must not half-commit"
      assert_nil task.completed_at
    end

    # --- Turbo Streams: adding a task must not repaint the whole page --------------

    # THE COMPLAINT: adding one row re-ran the ENTIRE show action — build log rich text, the Files
    # panel, every attachment thumbnail, the sheets — and repainted the page, losing the scroll
    # position. Now the response is one element.
    test "a turbo_stream add replaces only the tasks panel, and does not redirect" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      post project_tasks_path(project), params: { task: { title: "Print base" } }, as: :turbo_stream

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_select "turbo-stream[action=replace][target=project-tasks]", count: 1
      assert_match(/Print base/, response.body)
      # The rest of the page is genuinely absent — not merely not asserted.
      assert_no_match(/attachments-panel/, response.body)
      assert_no_match(/build-log/, response.body)
    end

    # THE DRIFT THIS PINS IS SILENT IN BOTH DIRECTIONS: rename the partial's root id and the stream
    # matches no element — the request still succeeds, the response is still 200, and the list just
    # stops updating with nothing in any log. Read from the response itself rather than from a
    # literal, so the two halves cannot be "fixed" apart.
    test "the stream target is the id the tasks partial actually renders" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      post project_tasks_path(project), params: { task: { title: "Print base" } }, as: :turbo_stream

      target = css_select("turbo-stream").first["target"]
      rendered_id = Nokogiri::HTML5.fragment(css_select("turbo-stream template").first.inner_html)
                                   .at_css("section")["id"]
      assert_equal target, rendered_id,
                   "the stream replaces ##{target} but the partial renders ##{rendered_id}"
    end

    test "status changes and deletes stream too, rather than reloading" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "Print base", status: "todo", position: 0)

      patch task_path(task), params: { task: { status: "done" } }, as: :turbo_stream
      assert_select "turbo-stream[action=replace][target=project-tasks]", count: 1
      assert_equal "done", task.reload.status

      delete task_path(task), as: :turbo_stream
      assert_select "turbo-stream[action=replace][target=project-tasks]", count: 1
      assert_equal 0, project.tasks.count
    end

    # A turbo_stream response replaces the panel and NOTHING ELSE, so `redirect_to ... alert:` would
    # set a flash no response ever draws: the user submits an invalid task, watches the panel redraw
    # unchanged, and is told nothing. The error renders inside the replaced element.
    test "an invalid task reports itself inside the replaced panel, not into a flash nobody draws" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      assert_no_difference "project.tasks.count" do
        post project_tasks_path(project), params: { task: { title: "" } }, as: :turbo_stream
      end
      assert_select "turbo-stream[target=project-tasks]"
      assert_match(/task-error/, response.body)
    end

    # THE NO-JS PATH IS NOT A COURTESY — everything the panel renders is plain form markup, so the
    # feature works with Turbo absent. An ordinary HTML post still redirects, exactly as before.
    test "without turbo_stream the redirect is unchanged" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      post project_tasks_path(project), params: { task: { title: "Print base" } }
      assert_redirected_to project_path(project)
      assert_equal "Task added.", flash[:notice]
    end
  end
end
