require "test_helper"

module Web
  # ADJUST STOCK KNOWS WHICH WAY IT GOES (UX audit 2026-11-01, E4). The reason was a label only, so
  # picking "Consumed" and typing 3 ADDED three. Now the reason gives the direction and the maker
  # types how many: Consumed takes it away, Restocked adds it, Adjusted takes a signed correction as
  # typed (Maker::InventoryTransaction.delta_for). Every post still goes through the ledger's one
  # door, apply!, so the balance is never edited directly.
  #
  # No library involvement: these pages read and write Maker::* rows only, the same on every backend.
  #
  # MUTATION-CHECKED (§15): `return amount unless sign` made unconditional in
  # Maker::InventoryTransaction.delta_for (the direction ignored) reddens "Consumed 3 from 10 leaves
  # 7" at 13 and the restock/sign tests; output in this task's report.
  class InventoryAdjustTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "adj-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
      @item = @user.maker_inventory_items.create!(name: "M3×8 screw", unit: "each")
      Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 10, reason: "initial")
    end

    def adjust!(amount, reason)
      post adjust_inventory_item_path(@item), params: { transaction: { amount:, reason: } }
      assert_redirected_to inventory_item_path(@item)
      @item.reload.quantity_cached
    end

    # Recent\x27s "Restock" link lands on a composer already set to Restocked (UX audit E6 review):
    # `?reason=` preselects, and anything outside ADJUST_REASONS falls back to Consumed.
    test "a reason in the query preselects the composer, and an unknown one falls back" do
      get inventory_item_path(@item, reason: "restocked")
      assert_response :success
      assert_select "select[name=\x27transaction[reason]\x27] option[selected][value=restocked]", count: 1
      get inventory_item_path(@item, reason: "initial")
      assert_select "select[name=\x27transaction[reason]\x27] option[selected][value=consumed]", count: 1
      assert_select "select[name=\x27transaction[reason]\x27] option[value=initial]", count: 0
    end

    test "Consumed 3 from 10 leaves 7" do
      assert_equal 7, adjust!("3", "consumed")
      assert_equal(-3, @item.transactions.last.delta)
      assert_equal "Consumed 3 each. 7 each on hand.", flash[:notice]
    end

    test "Restocked adds what was typed" do
      assert_equal 15, adjust!("5", "restocked")
      assert_equal "Restocked 5 each. 15 each on hand.", flash[:notice]
    end

    # THE REASON'S SIGN, SAID TWICE, IS STILL THE REASON'S: "-3" under Consumed is three out, never
    # three in, and "-5" under Restocked is five in.
    test "a sign typed under Consumed or Restocked does not turn the reason around" do
      assert_equal 7, adjust!("-3", "consumed")
      assert_equal 12, adjust!("-5", "restocked")
    end

    test "Adjusted takes the signed correction exactly as typed" do
      assert_equal 8, adjust!("-2", "adjusted")
      assert_equal "Adjusted by −2 each. 8 each on hand.", flash[:notice]
      assert_equal 10, adjust!("2", "adjusted")
    end

    test "the ledger names each change by its reason's word, and the composer explains the directions" do
      adjust!("3", "consumed")
      get inventory_item_path(@item)
      assert_response :success
      rows = css_select("table.table.ledger tbody tr")
      assert_select rows[0], "td.col-delta .delta-out", text: "−3"
      assert_select rows[0], "td.col-reason", text: "Consumed"
      assert_select rows[1], "td.col-reason", text: "Initial stock"
      assert_select "p.ledger-note", text: "Stock changes are recorded here; the balance is the sum."
      assert_select ".adjust #adjust-hint", text: /Consumed takes the amount away and Restocked adds it/
      assert_select ".adjust input[name='transaction[amount]'][aria-describedby='adjust-hint']"
      # The composer opens on the commonest move, Consumed.
      assert_select "select[name='transaction[reason]'] option[selected][value='consumed']"
    end
  end
end
