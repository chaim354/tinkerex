require "test_helper"
require "support/mcp_client"

module Mcp
  class TasksToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @token = bootstrap_token(email: "mcp-tasks@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-tasks@example.com")
      @lamp = @user.maker_projects.create!(name: "Lamp")
      @box = @user.maker_projects.create!(name: "Box")
    end

    test "list_tasks answers every project's tasks open first, or one project's, or one status" do
      done = @user.maker_tasks.create!(taskable: @lamp, title: "Done", status: "done", position: 0)
      open = @user.maker_tasks.create!(taskable: @lamp, title: "Open", position: 1)
      boxed = @user.maker_tasks.create!(taskable: @box, title: "Boxed", position: 2)

      out = mcp_structured(@token, "list_tasks")
      # Open first (the CASE), then position: open (1) before boxed (2), done last whatever its position.
      assert_equal [ open.id, boxed.id, done.id ], out["tasks"].map { |t| t["id"] }
      assert_equal %w[lamp box lamp], out["tasks"].map { |t| t["project"] }

      assert_equal [ open.id, done.id ], mcp_structured(@token, "list_tasks", { project: "lamp" })["tasks"].map { |t| t["id"] }
      assert_equal [ done.id ], mcp_structured(@token, "list_tasks", { status: "done" })["tasks"].map { |t| t["id"] }
      assert_equal "No project \"nope\".", mcp_refusal(@token, "list_tasks", { project: "nope" })
    end

    test "create_task attaches to the project and a done status stamps completed_at" do
      out = mcp_structured(@token, "create_task", { project: "lamp", title: "Cut base", notes: "3 mm ply" })
      task = @user.maker_tasks.find(out.dig("task", "id"))
      assert_equal @lamp, task.taskable
      assert_equal "todo", task.status
      assert_nil task.completed_at
      assert_equal "lamp", out.dig("task", "project")

      out = mcp_structured(@token, "create_task", { project: "lamp", title: "Already done", status: "done" })
      assert @user.maker_tasks.find(out.dig("task", "id")).completed_at.present?
    end

    test "update_task changes the given fields and follows the v1 completed_at rule" do
      task = @user.maker_tasks.create!(taskable: @lamp, title: "Cut")
      out = mcp_structured(@token, "update_task", { id: task.id, status: "done" })
      assert_equal "done", out.dig("task", "status")
      stamp = task.reload.completed_at
      assert stamp.present?

      mcp_structured(@token, "update_task", { id: task.id, title: "Cut base" })
      assert_equal stamp, task.reload.completed_at, "a title change keeps the stamp"

      mcp_structured(@token, "update_task", { id: task.id, status: "doing" })
      assert_nil task.reload.completed_at
      assert_equal "No task with id 0.", mcp_refusal(@token, "update_task", { id: 0, title: "x" })
    end

    test "list_build_log answers newest first, as plain text, limited" do
      3.times { |i| @lamp.build_log_entries.create!(user: @user, body: "entry #{i}", logged_at: i.days.ago) }
      out = mcp_structured(@token, "list_build_log", { project: "lamp", limit: 2 })
      assert_equal [ "entry 0", "entry 1" ], out["entries"].map { |e| e["body"] }
      assert_equal "lamp", out["project"]
    end

    test "add_build_log_entry keeps plain text plain, makes paragraphs, and takes a time" do
      out = mcp_structured(@token, "add_build_log_entry",
                           { project: "lamp", body: "Glued the base.\n\nLeft it <overnight>.",
                             entry_type: "milestone", logged_at: "2026-11-01T10:00:00Z" })
      entry = @lamp.build_log_entries.find(out.dig("entry", "id"))
      assert_equal "milestone", entry.entry_type
      assert_equal Time.utc(2026, 11, 1, 10), entry.logged_at
      assert_includes entry.body.to_s, "<p>Glued the base.</p>"
      assert_includes entry.body.to_s, "&lt;overnight&gt;"
      assert_equal "Glued the base.\n\nLeft it <overnight>.", out.dig("entry", "body")
    end

    test "add_build_log_entry refuses a time it cannot read, and defaults to now" do
      assert_match(/ISO-8601/, mcp_refusal(@token, "add_build_log_entry", { project: "lamp", body: "x", logged_at: "yesterday-ish" }))
      out = mcp_structured(@token, "add_build_log_entry", { project: "lamp", body: "now" })
      assert_in_delta Time.current, @lamp.build_log_entries.find(out.dig("entry", "id")).logged_at, 5
    end
  end
end
