require "test_helper"

module Web
  # SUPPLIERS AND LOCATIONS ARE REACHABLE FROM INVENTORY, AND THEIR COUNTS ARE WAYS IN (UX audit
  # 2026-11-01, E5). They were linked only from the Settings hub; the Inventory page and the item
  # form's empty Supplier/Location selects never pointed at them, and "2 items" was text. Now the
  # page head links both, an empty select says where its choices come from, and a count opens
  # Inventory narrowed by `?supplier=` / `?location=` — composable facets the chips and sort headers
  # carry, resolved through current_user. And a filter that matches nothing says so and offers the
  # way back, where it said "No inventory yet" (E3).
  #
  # No library involvement: these pages read and write Maker::* rows only.
  class InventoryPlacesTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "places-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
    end

    def item!(name, **attrs) = @user.maker_inventory_items.create!(name:, unit: "each", **attrs)

    test "the Inventory page links Suppliers and Locations beside its one action" do
      get inventory_items_path
      assert_select ".page-head .page-actions a.btn[href=?]", suppliers_path, text: "Suppliers"
      assert_select ".page-head .page-actions a.btn[href=?]", locations_path, text: "Locations"
      assert_select ".page-head .page-actions a.btn.primary", count: 1, text: "New item"
    end

    test "an empty Supplier or Location select links the page that fills it, and a filled one does not" do
      get new_inventory_item_path
      assert_select ".field select[name='inventory_item[location_id]'] ~ .field-hint a[href=?]", locations_path, text: "Add one"
      assert_select ".field select[name='inventory_item[supplier_id]'] ~ .field-hint a[href=?]", suppliers_path, text: "Add one"
      # The select keeps its own label, so its accessible name is still the field's.
      assert_select "label[for='inventory_item_location_id']", text: "Location"
      assert_select "label[for='inventory_item_supplier_id']", text: "Supplier"

      @user.maker_suppliers.create!(name: "McMaster")
      @user.maker_locations.create!(name: "Bin A1")
      get new_inventory_item_path
      assert_select ".field-hint a[href=?]", suppliers_path, count: 0
      assert_select ".field-hint a[href=?]", locations_path, count: 0
    end

    test "a supplier's count opens Inventory narrowed to it, and the facet rides the chips" do
      mcmaster = @user.maker_suppliers.create!(name: "McMaster")
      digikey = @user.maker_suppliers.create!(name: "Digikey")
      item!("Bolt", supplier: mcmaster, category: "Fasteners")
      item!("Nut", supplier: mcmaster, category: "Fasteners")
      item!("Resistor", supplier: digikey, category: "Fasteners")

      get suppliers_path
      assert_select "a.settings-fact[href=?]", inventory_items_path(supplier: mcmaster.id), text: "2 items"

      get inventory_items_path(supplier: mcmaster.id)
      assert_equal %w[Bolt Nut], css_select("td.col-name a").map(&:text)
      assert_select "a.filter.chip.active", text: "Supplier: McMaster"
      # Narrowing by category keeps the supplier, and so does re-sorting and searching.
      assert_select "a.filter.chip[href=?]", inventory_items_path(category: "Fasteners", supplier: mcmaster.id)
      assert_select "th a[href*=?]", "supplier=#{mcmaster.id}"
      assert_select "form.inventory-toolbar input[type=hidden][name=supplier][value=?]", mcmaster.id.to_s
      # "All" drops every facet.
      assert_select "a.filter.chip[href=?]", inventory_items_path, text: "All"
    end

    test "a location's count opens Inventory narrowed to it" do
      bin = @user.maker_locations.create!(name: "Bin A1")
      item!("Bolt", location: bin)
      item!("Nut")

      get locations_path
      assert_select "a.settings-fact[href=?]", inventory_items_path(location: bin.id), text: "1 item"
      get inventory_items_path(location: bin.id)
      assert_equal %w[Bolt], css_select("td.col-name a").map(&:text)
      assert_select "a.filter.chip.active", text: "Location: Bin A1"
    end

    test "the item page's supplier and location link to the items they hold" do
      supplier = @user.maker_suppliers.create!(name: "McMaster")
      location = @user.maker_locations.create!(name: "Bin A1")
      item = item!("Bolt", supplier:, location:)
      get inventory_item_path(item)
      assert_select "dl.meta dd a[href=?]", inventory_items_path(supplier: supplier.id), text: "McMaster"
      assert_select "dl.meta dd a[href=?]", inventory_items_path(location: location.id), text: "Bin A1"
    end

    # ANOTHER TENANT'S SUPPLIER NAMES NOTHING AND NARROWS TO NOTHING: never their name in a chip, and
    # never "every item" under an id that resolved to no row of ours.
    test "a foreign or unknown supplier id narrows to nothing and names nothing" do
      theirs = User.create!(email: "places-o-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                            omniauth_signup: true).maker_suppliers.create!(name: "Their Secret Supplier")
      item!("Bolt")

      get inventory_items_path(supplier: theirs.id)
      assert_response :success
      assert_select "table.inventory-table", 0
      assert_not_includes response.body, "Their Secret Supplier"

      get inventory_items_path(supplier: { "a" => "b" })
      assert_response :success
      assert_select "td.col-name a", text: "Bolt"
    end

    test "a filter that matches nothing says so and offers the way back" do
      item!("Bolt")
      get inventory_items_path(q: "zzz")
      assert_select "p.empty", text: /No items match/ do
        assert_select "a[href=?]", inventory_items_path, text: "Clear filters"
      end

      @user.maker_inventory_items.destroy_all
      get inventory_items_path
      assert_select "p.empty", text: /No inventory yet/ do
        assert_select "a[href=?]", new_inventory_item_path
      end
    end
  end
end
