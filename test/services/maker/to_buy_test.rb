require "test_helper"

module Maker
  # Maker::ToBuy: the shortfalls of every open project in one list, one row per item, in a constant
  # number of queries (spec 2026-11-18 §9, "To buy"). The arithmetic is Maker::BomRollup's
  # #short_by_item, so what is asserted here is the gathering: which projects, which revision,
  # which lines, which user, and how a shared item folds into one row.
  class ToBuyTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "to-buy-#{SecureRandom.hex(4)}@example.com")
    end

    test "a stock line short of its quantity is a row naming its project and the gap" do
      lamp = project!("Desk Lamp")
      mosfet = item!("AO3400A MOSFET", on_hand: 1, unit_cost: "0.12")
      line!(lamp, mosfet, 4)

      rows = Maker::ToBuy.for(@user)

      assert_equal 1, rows.size
      row = rows.first
      assert_equal mosfet, row.item
      assert_equal 3, row.short
      assert_equal 4, row.needed
      assert_equal 1, row.on_hand
      assert_equal [ [ lamp, 4 ] ], row.needs.map { |n| [ n.project, n.quantity ] }
      assert_equal BigDecimal("0.36"), row.cost
    end

    test "an item at or above what is needed is not on the list, and an uncosted item costs nil" do
      lamp = project!("Lamp")
      line!(lamp, item!("Exactly enough", on_hand: 4), 4)
      line!(lamp, item!("Plenty", on_hand: 9), 2)
      line!(lamp, item!("Uncosted", on_hand: 0), 1)

      rows = Maker::ToBuy.for(@user)

      assert_equal [ "Uncosted" ], rows.map { |r| r.item.name }
      assert_nil rows.first.cost
    end

    # THE SAME ITEM IN TWO PROJECTS IS ONE ROW. Neither project is short ALONE (3 on hand against 2
    # each, which is what each project's own BomRollup#short says), yet building both needs 4: the
    # list must say 1, and name both projects with what each needs.
    test "an item two projects need appears once, with both projects and the demand summed" do
      lamp = project!("Lamp")
      bench = project!("Bench")
      washers = item!("Washers M10", on_hand: 3)
      line!(lamp, washers, 2)
      line!(bench, washers, 2)

      assert_empty Maker::BomRollup.new(lamp.current_bom.lines.includes(:inventory_item)).short
      rows = Maker::ToBuy.for(@user)

      assert_equal 1, rows.size
      assert_equal 1, rows.first.short
      assert_equal 4, rows.first.needed
      assert_equal [ [ "Bench", 2 ], [ "Lamp", 2 ] ], rows.first.needs.map { |n| [ n.project.name, n.quantity ] }
    end

    test "two lines for one item in one project are one need, summed" do
      lamp = project!("Lamp")
      screws = item!("M3 screw", on_hand: 1)
      line!(lamp, screws, 2)
      line!(lamp, screws, 3)

      row = Maker::ToBuy.for(@user).sole

      assert_equal 4, row.short
      assert_equal [ [ lamp, 5 ] ], row.needs.map { |n| [ n.project, n.quantity ] }
    end

    test "only open projects count: planning, active and paused, never done or archived" do
      glue = item!("Wood glue", on_hand: 0)
      %w[planning active paused done archived].each { |status| line!(project!("P #{status}", status:), glue, 1) }

      row = Maker::ToBuy.for(@user).sole

      assert_equal 3, row.short
      assert_equal [ "P active", "P paused", "P planning" ], row.needs.map { |n| n.project.name }
    end

    test "only each project's current BOM revision counts" do
      lamp = project!("Lamp")
      old_only = item!("Dropped in rev 2", on_hand: 0)
      kept = item!("Kept", on_hand: 0)
      rev1 = lamp.boms.create!(user: @user, revision: 1)
      rev1.lines.create!(user: @user, inventory_item_id: old_only.id, quantity: 5)
      rev1.lines.create!(user: @user, inventory_item_id: kept.id, quantity: 5)
      rev2 = lamp.boms.create!(user: @user, revision: 2)
      rev2.lines.create!(user: @user, inventory_item_id: kept.id, quantity: 1)

      row = Maker::ToBuy.for(@user).sole

      assert_equal rev2, lamp.current_bom
      assert_equal kept, row.item
      assert_equal 1, row.short
    end

    test "typed-in parts and design files are never on the list" do
      lamp = project!("Lamp")
      bom = lamp.boms.create!(user: @user)
      bom.lines.create!(user: @user, part_name: "22 AWG wire", quantity: 10)
      bom.lines.create!(user: @user, node_id: "node-plate", quantity: 1)

      assert_equal [], Maker::ToBuy.for(@user)
    end

    test "another user's projects and shortfalls never appear" do
      line!(project!("Mine"), item!("Mine", on_hand: 0), 1)
      other = User.create!(email: "to-buy-other-#{SecureRandom.hex(4)}@example.com")
      theirs = other.maker_projects.create!(name: "Theirs")
      their_item = other.maker_inventory_items.create!(name: "Theirs")
      theirs.boms.create!(user: other).lines.create!(user: other, inventory_item_id: their_item.id, quantity: 9)

      assert_equal [ "Mine" ], Maker::ToBuy.for(@user).map { |r| r.item.name }
    end

    test "no open projects, or open projects with no BOM, is an empty list" do
      assert_equal [], Maker::ToBuy.for(@user)
      project!("Lamp")
      assert_equal [], Maker::ToBuy.for(@user)
    end

    test "rows are sorted by item name" do
      lamp = project!("Lamp")
      %w[washers Bolts anchors].each { |name| line!(lamp, item!(name, on_hand: 0), 1) }

      assert_equal %w[anchors Bolts washers], Maker::ToBuy.for(@user).map { |r| r.item.name }
    end

    # THE QUERY BUDGET: one open project or five, each with its own BOM, short items and an item
    # they share. Constancy, not a literal (page_query_budget_test.rb's rule).
    test "the list does not grow with the number of projects, BOMs or lines" do
      shared = item!("Shared", on_hand: 0)
      seed = lambda do |n, label|
        n.times do |i|
          project = project!("#{label} #{i}")
          line!(project, shared, 1)
          line!(project, item!("#{label} own #{i}", on_hand: 0), 2)
          project.current_bom.lines.create!(user: @user, part_name: "#{label} part #{i}", quantity: 1)
        end
      end

      seed.call(1, "Small")
      Maker::ToBuy.for(@user) # warm up
      small = count_queries { Maker::ToBuy.for(@user) }
      seed.call(4, "Large")
      large = count_queries { Maker::ToBuy.for(@user) }

      assert_equal small, large, "ToBuy issued #{small} queries for 1 project and #{large} for 5"
      rows = Maker::ToBuy.for(@user)
      assert_equal 6, rows.size # the shared item plus one of each project's own
      assert_equal 5, rows.find { |r| r.item == shared }.needs.size
    end

    private

    def project!(name, status: "active")
      @user.maker_projects.create!(name:, status:)
    end

    def item!(name, on_hand:, unit_cost: nil)
      item = @user.maker_inventory_items.create!(name:, unit_cost:)
      Maker::InventoryTransaction.apply!(item:, user: @user, delta: on_hand, reason: "initial") if on_hand.positive?
      item.reload
    end

    # A line on the project's current BOM, minting the BOM on the first line as the web door does.
    def line!(project, item, quantity)
      bom = project.current_bom || project.boms.create!(user: @user)
      bom.lines.create!(user: @user, inventory_item_id: item.id, quantity:)
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:sql].start_with?("PRAGMA") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end
  end
end
