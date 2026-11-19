require "test_helper"

module Web
  # TO BUY ON INVENTORY (Shop manual spec §9): the shortfalls of every open project in one list,
  # drawn as the inventory screen's section 1. What counts as short, and which projects and
  # revisions count, is Maker::ToBuy's (test/services/maker/to_buy_test.rb); what is asserted here
  # is what a row says, where the section stands, and when it is not drawn. Its query cost is
  # page_query_budget_test.rb's. Catalog rows only, no port.
  class InventoryToBuyTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "to-buy-web-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    test "each item an open project is short of is a row: how many to buy, why, and the cost" do
      lamp = project!("Desk Lamp")
      bench = project!("Workbench")
      mosfet = item!("AO3400A MOSFET", on_hand: 1, unit_cost: "0.12")
      washers = item!("Washers M10", on_hand: 3)
      plenty = item!("Pine 45 x 95", on_hand: 17)
      line!(lamp, mosfet, 4)
      line!(lamp, washers, 2)
      line!(bench, washers, 2)
      line!(bench, plenty, 2)

      get inventory_items_path
      assert_response :success

      heads = css_select("main .panel-head h2").map { |h| h.text.squish }
      assert_equal [ "1 To buy", "2 Stock" ], heads
      assert_select ".inventory-to-buy .panel-note", text: "2 items · about $0.36 for one of them"
      rows = css_select(".to-buy-table tbody tr").map { |tr| tr.css("td").map { |td| td.text.squish } }
      assert_equal [ [ "AO3400A MOSFET", "3 each", "Desk Lamp needs 4. 1 on hand.", "$0.12", "$0.36" ],
                     [ "Washers M10", "1 each", "Desk Lamp needs 2. Workbench needs 2. 3 on hand.", "—", "—" ] ], rows
      assert_select ".to-buy-table td.col-name a[href=?]", inventory_item_path(mosfet), text: "AO3400A MOSFET"
      assert_select ".to-buy-table td.col-why a[href=?]", project_path(lamp), text: "Desk Lamp", count: 2
      assert_select ".to-buy-table td.col-why a[href=?]", project_path(bench), text: "Workbench"
      assert_select ".page-lead", text: /Your open projects are short of two\.\z/
    end

    test "a costed list sums the whole bill" do
      line!(project!("Desk Lamp"), item!("AO3400A MOSFET", on_hand: 0, unit_cost: "0.15"), 6)

      get inventory_items_path

      assert_select ".inventory-to-buy .panel-note", text: "1 item · about $0.90"
    end

    test "with nothing short, there is no To buy section and Stock is section 1" do
      line!(project!("Desk Lamp"), item!("Plenty", on_hand: 9), 2)
      line!(project!("Shipped", status: "done"), item!("Used up", on_hand: 0), 2)

      get inventory_items_path

      assert_select ".inventory-to-buy", count: 0
      assert_equal [ "1 Stock" ], css_select("main .panel-head h2").map { |h| h.text.squish }
      assert_select ".page-lead", text: /None is low\.\z/
    end

    # A search or a facet narrows the stock; the shopping list is not stock a filter could narrow.
    test "a filtered list does not show To buy" do
      line!(project!("Desk Lamp"), item!("AO3400A MOSFET", on_hand: 0), 2)

      get inventory_items_path(q: "mosfet")

      assert_select ".inventory-to-buy", count: 0
      assert_select ".inventory-table .col-name a", text: "AO3400A MOSFET"
    end

    private

    def project!(name, status: "active")
      @user.maker_projects.create!(name:, status:)
    end

    def item!(name, on_hand:, unit_cost: nil)
      item = @user.maker_inventory_items.create!(name:, unit: "each", unit_cost:)
      Maker::InventoryTransaction.apply!(item:, user: @user, delta: on_hand, reason: "initial") if on_hand.positive?
      item.reload
    end

    def line!(project, item, quantity)
      bom = project.current_bom || project.boms.create!(user: @user)
      bom.lines.create!(user: @user, inventory_item_id: item.id, quantity:)
    end
  end
end
