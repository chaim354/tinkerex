require "test_helper"

module Web
  class ProjectTasksTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # The project detail view reads file metadata + capabilities through FileLayer.current; pin a
    # real backend so the share CI leg (no LIBRARY_PATH) doesn't fail on backend construction.
    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
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
    test "the add-task field is named for the key the controller requires" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      get project_path(project)
      assert_select "form.task-form input[type=text][name=?]", "task[title]"
    end

    test "submitting the add-task form as a browser does creates the task" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      get project_path(project)

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
  end
end
