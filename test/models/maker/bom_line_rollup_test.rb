require "test_helper"

module Maker
  # Rollup-resolution + exactly-one-target edge cases for BomLine not covered by
  # bom_line_test.rb: the design_file kind, the nil/dangling kind, and re-validating
  # exactly_one_target when an update SWITCHES the line's target shape.
  class BomLineRollupTest < ActiveSupport::TestCase
    setup do
      @user    = User.create!(email: "rollup@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
      @bom     = @project.boms.create!(user: @user)
      @inv     = @user.maker_inventory_items.create!(name: "M3 bolt", quantity_cached: 40)
    end

    test "resolved_target for a design_file line carries the node_id" do
      line = @bom.lines.create!(user: @user, node_id: "step-uuid", quantity: 1)
      resolved = line.resolved_target
      assert_equal :design_file, resolved[:kind]
      assert_equal "step-uuid", resolved[:node_id]
    end

    # `item.destroy!` no longer produces this state — `InventoryItem#release_bom_lines` converts the
    # line to a free-text part instead (audit A-M4; asserted in inventory_item_test.rb). The state is
    # still reachable on data stranded BEFORE that fix, so the graceful degradation still has to
    # hold; it is planted here rather than produced, because producing it is exactly what the fix
    # stopped doing.
    test "a dangling inventory ref resolves to a nil item rather than crashing" do
      line = @bom.lines.create!(user: @user, inventory_item_id: @inv.id, quantity: 4)
      line.update_columns(inventory_item_id: 999_999)
      resolved = line.reload.resolved_target
      assert_equal :inventory_item, resolved[:kind]
      assert_nil resolved[:inventory_item], "a dangling inventory ref resolves to nil, not a crash"
    end

    test "an update that SWITCHES from one target to another stays valid (exactly_one_target re-runs)" do
      line = @bom.lines.create!(user: @user, node_id: "n", quantity: 1)
      # Swap the design-file target for an inventory-item target (must clear node_id).
      assert line.update(node_id: nil, inventory_item_id: @inv.id)
      assert_equal :inventory_item, line.reload.target_kind
    end

    test "an update that leaves TWO targets is rejected (exactly_one_target re-runs on update)" do
      line = @bom.lines.create!(user: @user, node_id: "n", quantity: 1)
      # Add an inventory target WITHOUT clearing node_id => two targets => invalid.
      assert_not line.update(inventory_item_id: @inv.id)
      assert_includes line.errors[:base],
                      "a line must link exactly one of: inventory item, design file, or free-text part"
      assert_equal :design_file, line.reload.target_kind, "the rejected update must not persist"
    end

    test "an update that clears the ONLY target is rejected (zero targets)" do
      line = @bom.lines.create!(user: @user, node_id: "n", quantity: 1)
      assert_not line.update(node_id: nil)
      assert_equal "n", line.reload.node_id
    end

    test "lines order by position then id in the bom association" do
      a = @bom.lines.create!(user: @user, node_id: "a", quantity: 1, position: 2)
      b = @bom.lines.create!(user: @user, node_id: "b", quantity: 1, position: 1)
      assert_equal [ b.id, a.id ], @bom.lines.pluck(:id)
    end
  end
end
