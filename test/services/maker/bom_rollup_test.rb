require "test_helper"

module Maker
  # Maker::BomRollup computes its totals over lines the CALLER has already loaded (with
  # includes(:inventory_item)) -- it issues no query of its own. That is the one thing every
  # reader test here has to prove, alongside the arithmetic: counts by kind, estimated_cost's
  # nil-when-uncosted rule, and short's strict less-than boundary.
  class BomRollupTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "bom-rollup-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
      @bom = @project.boms.create!(user: @user)
    end

    test "counts lines by kind" do
      stock_item = item!
      @bom.lines.create!(user: @user, inventory_item_id: stock_item.id, quantity: 1)
      @bom.lines.create!(user: @user, node_id: "node-1", quantity: 1)
      @bom.lines.create!(user: @user, part_name: "22 AWG wire", quantity: 1)

      rollup = Maker::BomRollup.new(load_lines)

      assert_equal 3, rollup.count
      assert_equal({ inventory_item: 1, design_file: 1, free_text: 1 }, rollup.by_kind)
      assert_equal 1, rollup.stock_count
      assert_equal 1, rollup.file_count
      assert_equal 1, rollup.text_count
    end

    test "estimated_cost sums only costed stock lines, skipping uncosted stock and non-stock lines" do
      costed = item!(unit_cost: "11.50")
      uncosted = item!(unit_cost: nil)
      @bom.lines.create!(user: @user, inventory_item_id: costed.id, quantity: 2)
      @bom.lines.create!(user: @user, inventory_item_id: uncosted.id, quantity: 5)
      # A file line and a text line must not contribute even though quantity is set on both.
      @bom.lines.create!(user: @user, node_id: "node-2", quantity: 9)
      @bom.lines.create!(user: @user, part_name: "Bolt", quantity: 9)

      rollup = Maker::BomRollup.new(load_lines)

      assert_equal 23, rollup.estimated_cost # 2 x 11.50, the uncosted/file/text lines excluded
    end

    test "estimated_cost is nil when no line is costed" do
      uncosted = item!(unit_cost: nil)
      @bom.lines.create!(user: @user, inventory_item_id: uncosted.id, quantity: 3)
      @bom.lines.create!(user: @user, part_name: "Washer", quantity: 10)

      rollup = Maker::BomRollup.new(load_lines)

      assert_nil rollup.estimated_cost
    end

    test "short lists the stock line below quantity, and not the one at or above it" do
      short_item = item!
      Maker::InventoryTransaction.apply!(item: short_item, user: @user, delta: 1, reason: "initial")
      at_item = item!
      Maker::InventoryTransaction.apply!(item: at_item, user: @user, delta: 4, reason: "initial")
      above_item = item!
      Maker::InventoryTransaction.apply!(item: above_item, user: @user, delta: 5, reason: "initial")

      short_line = @bom.lines.create!(user: @user, inventory_item_id: short_item.id, quantity: 2)
      @bom.lines.create!(user: @user, inventory_item_id: at_item.id, quantity: 4)   # on_hand == quantity: not short
      @bom.lines.create!(user: @user, inventory_item_id: above_item.id, quantity: 2) # on_hand > quantity: not short

      rollup = Maker::BomRollup.new(load_lines)
      shorts = rollup.short

      assert_equal 1, shorts.size
      assert_equal short_line.id, shorts.first.line.id
      assert_equal 1, shorts.first.on_hand
    end

    test "an empty BOM answers zeros and nil" do
      rollup = Maker::BomRollup.new([])

      assert_equal 0, rollup.count
      assert_equal({}, rollup.by_kind)
      assert_equal 0, rollup.stock_count
      assert_equal 0, rollup.file_count
      assert_equal 0, rollup.text_count
      assert_nil rollup.estimated_cost
      assert_equal [], rollup.short
    end

    test "no reader issues a query when lines are loaded with includes(:inventory_item)" do
      item = item!(unit_cost: "5.00")
      Maker::InventoryTransaction.apply!(item: item, user: @user, delta: 1, reason: "initial")
      @bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 2)
      @bom.lines.create!(user: @user, node_id: "node-3", quantity: 1)
      @bom.lines.create!(user: @user, part_name: "Standoff", quantity: 4)

      rollup = Maker::BomRollup.new(load_lines) # loaded (and the association preloaded) before the block opens

      queries = count_queries do
        rollup.count
        rollup.by_kind
        rollup.stock_count
        rollup.file_count
        rollup.text_count
        rollup.estimated_cost
        rollup.short
      end

      assert_equal 0, queries
    end

    # #short_by_item asks #short's question once per ITEM, of the summed quantity: two lines of 2
    # against 3 on hand are fine line by line and 1 short together.
    test "short_by_item sums each item's lines and keeps only the items short of the sum" do
      shared = item!
      Maker::InventoryTransaction.apply!(item: shared, user: @user, delta: 3, reason: "initial")
      enough = item!
      Maker::InventoryTransaction.apply!(item: enough, user: @user, delta: 5, reason: "initial")
      first = @bom.lines.create!(user: @user, inventory_item_id: shared.id, quantity: 2)
      @bom.lines.create!(user: @user, inventory_item_id: enough.id, quantity: 5)
      second = @bom.lines.create!(user: @user, inventory_item_id: shared.id, quantity: 2)
      @bom.lines.create!(user: @user, part_name: "Bolt", quantity: 9)
      @bom.lines.create!(user: @user, node_id: "node-4", quantity: 9)

      rollup = Maker::BomRollup.new(load_lines)

      assert_empty rollup.short # each line alone fits in 3
      shorts = rollup.short_by_item
      assert_equal 1, shorts.size
      s = shorts.first
      assert_equal shared.id, s.item.id
      assert_equal 4, s.needed
      assert_equal 3, s.on_hand
      assert_equal 1, s.short
      assert_equal [ first.id, second.id ], s.lines.map(&:id)
    end

    test "short_by_item reports every item short reports, at or above its shortfall" do
      a = item!
      b = item!
      Maker::InventoryTransaction.apply!(item: b, user: @user, delta: 1, reason: "initial")
      @bom.lines.create!(user: @user, inventory_item_id: a.id, quantity: 1)
      @bom.lines.create!(user: @user, inventory_item_id: b.id, quantity: 2)
      @bom.lines.create!(user: @user, inventory_item_id: b.id, quantity: 2)

      rollup = Maker::BomRollup.new(load_lines)

      assert_equal rollup.short.map { |s| s.line.inventory_item_id }.uniq, rollup.short_by_item.map { |s| s.item.id }
      assert_equal [ 1, 3 ], rollup.short_by_item.map(&:short)
    end

    test "short_by_item leaves out a dangling item and issues no query" do
      gone = item!
      line = @bom.lines.create!(user: @user, inventory_item_id: gone.id, quantity: 2)
      line.update_columns(inventory_item_id: 999_999)

      rollup = Maker::BomRollup.new(load_lines)

      assert_equal 0, count_queries { rollup.short_by_item }
      assert_equal [], rollup.short_by_item
    end

    private

    def load_lines
      @bom.lines.includes(:inventory_item).to_a
    end

    def item!(unit_cost: nil)
      @user.maker_inventory_items.create!(name: "Item #{SecureRandom.hex(3)}", unit_cost: unit_cost)
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end
  end
end
