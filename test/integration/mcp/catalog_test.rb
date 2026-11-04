require "test_helper"
require "support/mcp_client"

module Mcp
  # THE CATALOG AS THE CLIENT SEES IT (spec §3, §4): the 24 names in order, every tool annotated in
  # full, every schema closed. A tool that forgot `reads!` would be presented as destructive, and a
  # schema without additionalProperties: false lets a misspelt argument through to a keyword error.
  class CatalogTest < ActionDispatch::IntegrationTest
    include McpClient

    NAMES = %w[
      list_projects get_project create_project update_project
      list_tasks create_task update_task
      list_build_log add_build_log_entry
      list_inventory get_inventory_item create_inventory_item update_inventory_item adjust_inventory
      get_bom add_bom_line update_bom_line
      list_suppliers create_supplier list_locations create_location
      list_folder read_text_file search
    ].freeze
    READS = NAMES.grep(/\A(list_|get_|read_|search)/).freeze
    IDEMPOTENT_WRITES = NAMES.grep(/\Aupdate_/).freeze

    setup { @token = bootstrap_token(email: "mcp-catalog@example.com", device_name: "assistant") }

    test "tools/list is exactly the 24 tools, in order" do
      tools = mcp_rpc(@token, "tools/list").dig("result", "tools")
      assert_equal NAMES, tools.map { |t| t["name"] }
    end

    test "every tool is annotated in full, closed to unknown arguments, and described" do
      tools = mcp_rpc(@token, "tools/list").dig("result", "tools")
      tools.each do |t|
        name = t["name"]
        annotations = t.fetch("annotations") { flunk "#{name} has no annotations" }
        assert_equal %w[destructiveHint idempotentHint openWorldHint readOnlyHint], annotations.keys.sort, name
        assert_equal false, annotations["destructiveHint"], "#{name} must not read as destructive"
        assert_equal false, annotations["openWorldHint"], "#{name} acts on a closed dataset"
        assert_equal READS.include?(name), annotations["readOnlyHint"], name
        assert_equal(READS.include?(name) || IDEMPOTENT_WRITES.include?(name), annotations["idempotentHint"], name)
        assert_equal false, t.dig("inputSchema", "additionalProperties"), "#{name}'s schema must be closed"
        # A description is what the model chooses a tool BY; one sentence that names the thing and
        # its arguments is the floor, and a tool that never called `description` is nil, so 0.
        assert_operator t["description"].to_s.length, :>=, 40, "#{name} needs a real description"
      end
    end
  end
end
