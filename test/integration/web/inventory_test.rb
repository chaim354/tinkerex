require "test_helper"

module Web
  # Inventory on the web (stage 2, S2-3): the table, the item page, and Adjust posting through
  # Maker::InventoryTransaction.apply! — the ledger's one door. No FileLayer/library involvement
  # anywhere here (unlike files_*_test.rb): these controllers read and write Maker::* rows only.
  class InventoryTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "inv-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    def item!(name, **attrs)
      @user.maker_inventory_items.create!(name:, unit: "each", **attrs)
    end

    def post!(item, delta, reason:, project_id: nil)
      Maker::InventoryTransaction.apply!(item:, user: @user, delta:, reason:, project_id:)
    end

    def other_user!
      User.create!(email: "inv-other-#{SecureRandom.hex(4)}@example.com",
                   confirmed_at: Time.current, omniauth_signup: true)
    end

    # --- index -----------------------------------------------------------------------------

    test "index lists items with their facts and links each row" do
      location = @user.maker_locations.create!(name: "Bin A1")
      supplier = @user.maker_suppliers.create!(name: "McMaster")
      a = item!("M3×8 screw", min_quantity: 50, location:, supplier:)
      post!(a, 12, reason: "initial")
      item!("Nylon washer")
      item!("Threaded insert")

      get inventory_items_path
      assert_response :success
      assert_select "table.table.inventory-table tbody tr", 3
      assert_select "td.col-name a[href=?]", inventory_item_path(a), text: "M3×8 screw"
      assert_select ".col-onhand", text: /12 each/
      assert_select ".col-location", text: /Bin A1/
      assert_select ".col-supplier", text: /McMaster/
    end

    test "low stock is a badge, a chip and a scope" do
      low = item!("M3×8 screw", min_quantity: 50)
      post!(low, 12, reason: "initial")
      ok = item!("Nylon washer", min_quantity: 10)
      post!(ok, 100, reason: "initial")

      get inventory_items_path
      assert_select "tr.low-stock", 1
      assert_select "tr.low-stock .badge.low-stock"

      get inventory_items_path(low: 1)
      assert_select "table.table.inventory-table tbody tr", 1
      assert_select "td.col-name", text: /M3×8 screw/
      assert_select "a.filter.chip.active[href=?]", inventory_items_path(low: 1), text: /Low stock \(1\)/
    end

    test "search matches name or part number, case-insensitively, with % escaped" do
      screw = item!("M3×8 screw", part_number: "91290A115")
      item!("Nylon washer", part_number: "91090A114")
      item!("100% cotton")

      get inventory_items_path(q: "m3")
      assert_select "table.table.inventory-table tbody tr", 1
      assert_select "td.col-name", text: /M3×8 screw/

      get inventory_items_path(q: "91290")
      assert_select "table.table.inventory-table tbody tr", 1
      assert_select "td.col-name a[href=?]", inventory_item_path(screw)

      # A LITERAL "%" IN THE QUERY MUST NOT BEHAVE AS A WILDCARD (mutation b: drop ESCAPE '\' and
      # this matches everything, because SQLite has no default LIKE escape character).
      get inventory_items_path(q: "100%")
      assert_select "table.table.inventory-table tbody tr", 1
      assert_select "td.col-name", text: /100% cotton/
    end

    test "category chips come from the user's own categories" do
      bolt = item!("Bolt", category: "Fasteners")
      item!("Resistor", category: "Electronics")

      get inventory_items_path
      assert_select "span.chips a.filter.chip", 4 # All, Low stock, Fasteners, Electronics

      get inventory_items_path(category: "Fasteners")
      assert_select "table.table.inventory-table tbody tr", 1
      assert_select "td.col-name a[href=?]", inventory_item_path(bolt)
      assert_select "a.filter.chip.active", text: "Fasteners"
    end

    test "sort orders by the chosen column and direction, defaulting to name ascending" do
      alpha = item!("Alpha")
      post!(alpha, 30, reason: "initial")
      bravo = item!("Bravo")
      post!(bravo, 10, reason: "initial")

      get inventory_items_path
      assert_equal [ "Alpha", "Bravo" ], css_select("td.col-name a").map(&:text)

      get inventory_items_path(sort: "quantity", dir: "asc")
      assert_equal [ "Bravo", "Alpha" ], css_select("td.col-name a").map(&:text)
      assert_select "th.sorted[aria-sort=?]", "ascending"
      assert_select "th.sorted a", text: /On hand/
    end

    # --- item page: facts, composer, ledger -------------------------------------------------

    test "the item page shows the strip, the composer and the ledger with balances" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      location = @user.maker_locations.create!(name: "Bin A1")
      supplier = @user.maker_suppliers.create!(name: "McMaster")
      item = item!("M3×8 screw", part_number: "91290A115", category: "Fasteners",
                   min_quantity: 50, unit_cost: 0.25, location:, supplier:)
      post!(item, 50, reason: "initial")
      post!(item, -30, reason: "consumed", project_id: project.id)
      post!(item, -8, reason: "consumed")

      get inventory_item_path(item)
      assert_response :success

      assert_select "dl.meta" do
        assert_select "dt", text: "Part #"
        assert_select "dt", text: "Category"
        assert_select "dt", text: "On hand"
        assert_select "dt", text: "Unit cost"
        assert_select "dt", text: "Location"
        assert_select "dt", text: "Supplier"
      end
      assert_select "dl.meta dd", text: "12 each · min 50"

      assert_select "details.composer.adjust[open]" do
        assert_select "select[name='transaction[reason]']" do
          Maker::InventoryTransaction::REASONS.each { |r| assert_select "option[value=?]", r }
        end
        assert_select "select[name='transaction[project_id]']" do
          assert_select "option", text: "Desk Lamp"
        end
        assert_select "input[name='transaction[delta]']"
        assert_select "input[name='transaction[note]']"
      end

      rows = css_select("table.table.ledger tbody tr")
      assert_equal 3, rows.size

      assert_select rows[0], "td.col-delta .delta-out", text: "−8"
      assert_select rows[0], "td.col-balance", text: "12"

      assert_select rows[1], "td.col-delta .delta-out", text: "−30"
      assert_select rows[1], "td.col-balance", text: "20"
      assert_select rows[1], "td.col-project a[href=?]", project_path(project), text: "Desk Lamp"

      assert_select rows[2], "td.col-delta .delta-in", text: "+50"
      assert_select rows[2], "td.col-balance", text: "50"
      assert_select rows[2], "td", text: "initial"
    end

    test "the ledger is capped" do
      item = item!("Bulk part")
      rows = (InventoryItemsController::LEDGER_CAP + 1).times.map do |i|
        { user_id: @user.id, inventory_item_id: item.id, delta: 1, reason: "restocked",
          created_at: Time.current + i.seconds }
      end
      Maker::InventoryTransaction.insert_all(rows)
      item.rebuild_quantity_cached!

      get inventory_item_path(item)
      assert_response :success
      assert_select "table.table.ledger tbody tr", InventoryItemsController::LEDGER_CAP
      assert_select "p.ledger-truncated", text: /Showing 200 of 201/
    end

    # --- adjust ------------------------------------------------------------------------------

    test "adjust posts through apply! and redirects with a signed flash" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      item = item!("Screws", min_quantity: 1)
      post!(item, 12, reason: "initial")

      post adjust_inventory_item_path(item),
           params: { transaction: { delta: "-8", reason: "consumed", project_id: project.id, note: "base" } }

      assert_redirected_to inventory_item_path(item)
      assert_match(/Posted −8 each \(consumed\)/, flash[:notice])
      assert_equal 4, item.reload.quantity_cached.to_i
      last = item.transactions.reorder(created_at: :desc, id: :desc).first
      assert_equal project.id, last.project_id
      assert_equal "base", last.note
      assert_equal "consumed", last.reason
    end

    test "adjust refuses a zero delta" do
      item = item!("Screws")
      post!(item, 12, reason: "initial")

      assert_no_difference -> { item.transactions.count } do
        post adjust_inventory_item_path(item), params: { transaction: { delta: "0", reason: "consumed" } }
      end
      assert_redirected_to inventory_item_path(item)
      assert_match(/Enter a non-zero/, flash[:alert])
    end

    test "adjust refuses a non-numeric delta" do
      item = item!("Screws")
      post!(item, 12, reason: "initial")

      assert_no_difference -> { item.transactions.count } do
        post adjust_inventory_item_path(item), params: { transaction: { delta: "not-a-number", reason: "consumed" } }
      end
      assert_redirected_to inventory_item_path(item)
      assert_match(/Enter a non-zero/, flash[:alert])
    end

    test "adjust drops a foreign project id but still posts" do
      theirs = other_user!
      foreign_project = theirs.maker_projects.create!(name: "Not yours")
      item = item!("Screws")
      post!(item, 12, reason: "initial")

      post adjust_inventory_item_path(item),
           params: { transaction: { delta: "5", reason: "restocked", project_id: foreign_project.id } }

      assert_redirected_to inventory_item_path(item)
      assert_match(/Posted \+5 each \(restocked\)/, flash[:notice])
      last = item.transactions.reorder(created_at: :desc, id: :desc).first
      assert_nil last.project_id
    end

    test "adjust refuses a reason outside REASONS" do
      item = item!("Screws")
      post!(item, 12, reason: "initial")

      assert_no_difference -> { item.transactions.count } do
        post adjust_inventory_item_path(item), params: { transaction: { delta: "5", reason: "bogus" } }
      end
      assert_response(:redirect) # alert-flash shape, not a 422 — either is allowed by the plan
      assert_match(/reason/i, flash[:alert])
    end

    test "the ledger has no edit or delete door" do
      item = item!("Screws")
      post!(item, 12, reason: "initial")
      txn = item.transactions.first

      patch "/inventory/#{item.id}/transactions/#{txn.id}"
      assert_response :not_found
      delete "/inventory/#{item.id}/transactions/#{txn.id}"
      assert_response :not_found

      get inventory_item_path(item)
      assert_select "form[action*='transactions']", 0
    end

    # --- new / create --------------------------------------------------------------------------

    test "new renders the field names the controller reads" do
      get new_inventory_item_path
      assert_response :success
      assert_select "input[name='inventory_item[name]']"
      assert_select "select[name='inventory_item[unit]']" do
        Maker::InventoryItem::UNITS.each { |u| assert_select "option[value=?]", u }
      end
      assert_select "select[name='inventory_item[location_id]']"
      assert_select "select[name='inventory_item[supplier_id]']"
      assert_select "input[name='inventory_item[initial_quantity]']"
    end

    test "edit has no initial-quantity field" do
      item = item!("Existing")
      get edit_inventory_item_path(item)
      assert_response :success
      assert_select "input[name='inventory_item[initial_quantity]']", 0
    end

    test "create with an initial quantity writes an initial transaction, never the column" do
      post inventory_items_path, params: { inventory_item: {
        name: "PETG black", unit: "kg", min_quantity: "1", initial_quantity: "2.5", category: "Filament"
      } }

      item = @user.maker_inventory_items.find_by!(name: "PETG black")
      assert_redirected_to inventory_item_path(item)
      assert_equal 1, item.transactions.count
      txn = item.transactions.first
      assert_equal "initial", txn.reason
      assert_equal 2.5, txn.delta.to_f
      assert_equal 2.5, item.reload.quantity_cached.to_f
    end

    test "create with a blank initial quantity writes no transaction" do
      post inventory_items_path, params: { inventory_item: {
        name: "PLA white", unit: "kg", min_quantity: "1"
      } }

      item = @user.maker_inventory_items.find_by!(name: "PLA white")
      assert_equal 0, item.transactions.count
      assert_equal 0, item.quantity_cached.to_i
    end

    # --- edit / update --------------------------------------------------------------------------

    test "update changes facts and never quantity_cached" do
      item = item!("Widget", min_quantity: 1)
      post!(item, 20, reason: "initial")

      patch inventory_item_path(item), params: { inventory_item: { name: "Widget v2", quantity_cached: "999" } }

      assert_redirected_to inventory_item_path(item)
      item.reload
      assert_equal "Widget v2", item.name
      assert_equal 20, item.quantity_cached.to_i
    end

    test "a foreign location is refused on create, and the form re-renders with the model's error" do
      theirs = other_user!
      their_location = theirs.maker_locations.create!(name: "Their shelf")

      post inventory_items_path, params: { inventory_item: {
        name: "Bad", unit: "each", min_quantity: "0", location_id: their_location.id
      } }

      assert_response :unprocessable_entity
      assert_select ".form-errors", text: /location/i
      assert_nil @user.maker_inventory_items.find_by(name: "Bad")
    end

    test "a foreign supplier is refused on update, and the form re-renders with the model's error" do
      theirs = other_user!
      their_supplier = theirs.maker_suppliers.create!(name: "Their supplier")
      item = item!("Widget")

      patch inventory_item_path(item), params: { inventory_item: { supplier_id: their_supplier.id } }

      assert_response :unprocessable_entity
      assert_select ".form-errors", text: /supplier/i
      assert_nil item.reload.supplier_id
    end

    # --- destroy -----------------------------------------------------------------------------

    test "destroy releases BOM lines and deletes the ledger" do
      item = item!("Bolt")
      post!(item, 5, reason: "initial")
      project = @user.maker_projects.create!(name: "Desk Lamp")
      bom = @user.maker_boms.create!(project:, name: "Main BOM", revision: 1)
      line = bom.lines.create!(user: @user, inventory_item: item, quantity: 2, unit: "each")

      delete inventory_item_path(item)

      assert_redirected_to inventory_items_path
      assert_match(/Deleted Bolt/, flash[:notice])
      assert_nil Maker::InventoryItem.find_by(id: item.id)
      line.reload
      assert_equal "Bolt", line.part_name
      assert_nil line.inventory_item_id
      assert_equal 0, Maker::InventoryTransaction.where(inventory_item_id: item.id).count
    end

    # --- tenancy -------------------------------------------------------------------------------

    test "a foreign item 404s on show, edit, adjust and destroy" do
      theirs = other_user!
      foreign = theirs.maker_inventory_items.create!(name: "Theirs", unit: "each")

      get inventory_item_path(foreign)
      assert_response :not_found
      get edit_inventory_item_path(foreign)
      assert_response :not_found
      post adjust_inventory_item_path(foreign), params: { transaction: { delta: "1", reason: "restocked" } }
      assert_response :not_found
      delete inventory_item_path(foreign)
      assert_response :not_found
    end
  end
end
