require "test_helper"

module Web
  # A MINIMUM OF 0 IS NO MINIMUM, SO IT IS NEVER "LOW" (UX audit 2026-11-01, E5). Every item is
  # created at the column's min_quantity 0, and `quantity_cached <= min_quantity` called a brand-new
  # item, or anything run down to nothing, "Low" before anyone said how many they want to keep. The
  # scope and Maker::InventoryItem#low_stock? are the one definition, and every surface reads one of
  # them: the list's badge and row class, its "Low stock" chip, the item page and Recent.
  #
  # And ONE WORD for it: "Low stock" on the chip, the list's badge and the item page (it was "Low" on
  # the list); the column is "Minimum" (it was "Min"), the form's label "Minimum quantity".
  #
  # MUTATION-CHECKED (§15): putting the scope back to `quantity_cached <= min_quantity` reddens the
  # chip count and Recent arms; putting `low_stock?` back to `quantity_cached <= min_quantity`
  # reddens the list and item-page arms. Outputs in this task's report.
  class InventoryLowStockTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "low-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
      # A NEW ITEM, exactly as the form makes one: no minimum typed, nothing in stock.
      @fresh = @user.maker_inventory_items.create!(name: "Fresh bolt", unit: "each")
      # THE POSITIVE CONTROL, so every "not low" below can fail: an item under a minimum it set.
      @short = @user.maker_inventory_items.create!(name: "Short washer", unit: "each", min_quantity: 50)
      Maker::InventoryTransaction.apply!(item: @short, user: @user, delta: 12, reason: "initial")
    end

    test "a new item with no minimum is not low on the list, the chip or its page" do
      get inventory_items_path
      assert_response :success
      assert_select "tr.low-stock", 1
      assert_select "tr.low-stock td.col-name", text: /Short washer/
      assert_select "tr.low-stock td.col-name", text: /Fresh bolt/, count: 0
      assert_select "a.filter.chip", text: "Low stock (1)"

      get inventory_items_path(low: 1)
      assert_equal [ "Short washer" ], css_select("td.col-name a").map(&:text)

      get inventory_item_path(@fresh)
      assert_select ".page-head .badge.low-stock", 0
      get inventory_item_path(@short)
      assert_select ".page-head .badge.low-stock", text: "Low stock"
    end

    test "Recent's Needs attention lists the short item and not the new one" do
      get root_path
      assert_select ".home-attention .attention-row--warn", text: /Short washer/
      assert_select ".home-attention .attention-row--warn", text: /Fresh bolt/, count: 0
    end

    test "low stock has one word, and a minimum of 0 reads as none" do
      get inventory_items_path
      assert_select "tr.low-stock .badge.low-stock", text: "Low stock"
      assert_select "th.col-min", text: "Minimum"
      assert_select "tr:not(.low-stock) td.col-min", text: "—"

      get inventory_item_path(@short)
      assert_select "dl.meta dd", text: "12 each · minimum 50"
      get inventory_item_path(@fresh)
      assert_select "dl.meta dd", text: "0 each"

      get new_inventory_item_path
      assert_select "label.field", text: /Minimum quantity/ do
        assert_select "input[name='inventory_item[min_quantity]']"
      end
    end
  end
end
