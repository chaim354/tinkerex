require "test_helper"
require "support/mcp_client"

module Mcp
  # THE HEADLINE TEST (spec §8, §9): user A's token reaches none of user B's data, by any tool, read
  # or write. Every finder in McpServer::Tool starts from the user; this is what makes that a
  # guard rather than a convention. Mutation-checked by dropping `user.` from one finder.
  class IsolationTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @a = bootstrap_token(email: "mcp-a@example.com", device_name: "assistant")
      bootstrap_token(email: "mcp-b@example.com", device_name: "assistant")
      @b = User.find_by!(email: "mcp-b@example.com")
      @theirs = @b.maker_projects.create!(name: "Theirs")
      project_folder_rows!(@b, @theirs)
      @task = @b.maker_tasks.create!(taskable: @theirs, title: "Their task")
      @item = @b.maker_inventory_items.create!(name: "Their bolts")
      @bom = @theirs.boms.create!(user: @b)
      @line = @bom.lines.create!(user: @b, part_name: "Their part")
      @secret = @b.nodes.create!(node_id: SecureRandom.uuid, name: "Secret", kind: "dir", mtime: 1, size: 0)
      @b.nodes.create!(node_id: SecureRandom.uuid, name: "plans.md", kind: "file", parent_node_id: @secret.node_id, mtime: 1, size: 5)
      # A file that MATCHES the search below, so search's `files` arm is a claim and not vacuous.
      @b.nodes.create!(node_id: SecureRandom.uuid, name: "their-notes.txt", kind: "file", parent_node_id: @secret.node_id, mtime: 1, size: 5)
    end

    test "reads answer nothing of the other user's" do
      assert_equal [], mcp_structured(@a, "list_projects")["projects"]
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "get_project", { slug: "theirs" })
      assert_equal [], mcp_structured(@a, "list_tasks")["tasks"]
      assert_equal "No inventory item with id #{@item.id}.", mcp_refusal(@a, "get_inventory_item", { id: @item.id })
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "get_bom", { project: "theirs" })
      assert_equal [], mcp_structured(@a, "list_folder")["entries"]
      assert_equal "No file or folder at \"Secret\".", mcp_refusal(@a, "list_folder", { path: "Secret" })
      assert_equal "No file or folder at \"Secret/plans.md\".", mcp_refusal(@a, "read_text_file", { path: "Secret/plans.md" })
      out = mcp_structured(@a, "search", { q: "their" })
      assert_equal [ [], [], [], [] ], out.values_at("files", "folders", "projects", "inventory")
    end

    test "writes change nothing of the other user's" do
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "update_project", { slug: "theirs", name: "Mine now" })
      assert_equal "Theirs", @theirs.reload.name
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "create_task", { project: "theirs", title: "x" })
      assert_equal "No task with id #{@task.id}.", mcp_refusal(@a, "update_task", { id: @task.id, status: "done" })
      assert_equal "todo", @task.reload.status
      assert_equal "No inventory item with id #{@item.id}.", mcp_refusal(@a, "adjust_inventory", { id: @item.id, delta: 5 })
      assert_equal 0, @item.reload.quantity_cached
      assert_equal "No BOM line with id #{@line.id}.", mcp_refusal(@a, "update_bom_line", { id: @line.id, quantity: 9 })
      assert_equal 1, @line.reload.quantity
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "add_build_log_entry", { project: "theirs", body: "x" })
      assert_empty @theirs.build_log_entries
    end

    test "a write on your own row cannot point at the other user's rows" do
      mine = User.find_by!(email: "mcp-a@example.com").maker_projects.create!(name: "Mine")
      message = mcp_refusal(@a, "add_bom_line", { project: "mine", inventory_item_id: @item.id })
      assert_match(/Inventory item/i, message)
      assert_empty mine.boms.flat_map(&:lines)
    end
  end
end
