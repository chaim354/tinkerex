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
  end
end
