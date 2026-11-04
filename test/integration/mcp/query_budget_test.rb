require "test_helper"
require "support/mcp_client"

module Mcp
  # CONSTANCY IN N, NEVER A LITERAL (page_query_budget_test.rb's rule, for the same reason: the
  # counts differ per LIBRARY_BACKEND, and the property that matters is that a tool does not grow
  # with the data it renders).
  class QueryBudgetTest < ActionDispatch::IntegrationTest
    include McpClient

    SMALL = 3
    LARGE = 15

    setup do
      @token = bootstrap_token(email: "mcp-budget@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-budget@example.com")
    end

    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        n += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # Warm once, measure, grow, warm, measure.
    def assert_constant(name, arguments, grow)
      grow.call(SMALL)
      mcp_structured(@token, name, arguments)
      small = count_queries { mcp_structured(@token, name, arguments) }
      grow.call(LARGE - SMALL)
      mcp_structured(@token, name, arguments)
      large = count_queries { mcp_structured(@token, name, arguments) }
      assert_equal small, large, "#{name} issued #{small} queries at the small size and #{large} at the large one"
    end

    test "get_project does not grow with tasks, entries, BOMs or attachments" do
      lamp = @user.maker_projects.create!(name: "Lamp")
      folder = project_folder_rows!(@user, lamp)
      grow = lambda do |n|
        n.times do |i|
          @user.maker_tasks.create!(taskable: lamp, title: "t#{i}")
          lamp.build_log_entries.create!(user: @user, body: "e#{i}", logged_at: Time.current)
          lamp.boms.create!(user: @user, revision: lamp.boms.count + 1).lines.create!(user: @user, part_name: "p#{i}")
          node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "f#{i}.stl", kind: "file", parent_node_id: folder.node_id, mtime: 1, size: 1)
          lamp.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
        end
      end
      assert_constant("get_project", { slug: "lamp" }, grow)
    end

    test "list_projects does not grow with projects" do
      grow = ->(n) { n.times { |i| project_folder_rows!(@user, @user.maker_projects.create!(name: "P#{SecureRandom.hex(3)}")) } }
      assert_constant("list_projects", {}, grow)
    end

    test "list_folder, list_tasks, list_inventory and get_bom do not grow with rows" do
      root = @user.nodes.create!(node_id: SecureRandom.uuid, name: "Stuff", kind: "dir", mtime: 1, size: 0)
      assert_constant("list_folder", { path: "Stuff" }, ->(n) { n.times { |i| @user.nodes.create!(node_id: SecureRandom.uuid, name: "n#{SecureRandom.hex(3)}.txt", kind: "file", parent_node_id: root.node_id, mtime: 1, size: 1) } })
      lamp = @user.maker_projects.create!(name: "Lamp")
      assert_constant("list_tasks", {}, ->(n) { n.times { |i| @user.maker_tasks.create!(taskable: lamp, title: "t#{i}") } })
      loc = @user.maker_locations.create!(name: "Bench")
      assert_constant("list_inventory", {}, ->(n) { n.times { |i| @user.maker_inventory_items.create!(name: "i#{SecureRandom.hex(3)}", location: loc) } })
      bom = lamp.boms.create!(user: @user)
      item = @user.maker_inventory_items.create!(name: "bolt")
      assert_constant("get_bom", { project: "lamp" }, ->(n) { n.times { bom.lines.create!(user: @user, inventory_item: item, quantity: 1) } })
    end
  end
end
