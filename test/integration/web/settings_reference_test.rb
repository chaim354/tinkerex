require "test_helper"

module Web
  # Task B (S2-3): the two settings reference lists, Suppliers and Locations, in the shape of
  # Shelves (test/integration/web/shelves_test.rb) -- a flat list, one row per record, an inline
  # add form, a Remove button, all session-authed (§14d). Both controllers hand every stock-item
  # reference to `dependent: :nullify` on the model (Maker::Supplier, Maker::Location), so removing
  # a reference row never locks or destroys what pointed at it -- see those models' own comments.
  #
  # NO BACKEND IS PINNED HERE, for the same reason shelves_test.rb gives: neither controller reads
  # `nodes` or calls the port at all, so there is nothing for FileLayer.current to answer and
  # nothing for the ambient LIBRARY_BACKEND to change.
  class SettingsReferenceTest < ActionDispatch::IntegrationTest
    PASSWORD = "password123".freeze

    setup do
      @user = User.create!(email: "sr-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_as(@user)
    end

    # The harness's verifying sign-in (test_helper.rb's `sign_in_web!`), with this suite's own
    # PASSWORD rather than WEB_PASSWORD.
    def sign_in_as(user) = sign_in_web!(user, password: PASSWORD)

    def other_user!
      User.create!(email: "sro-#{SecureRandom.hex(4)}@example.com",
                  confirmed_at: Time.current, omniauth_signup: true)
    end

    # ============================================================ Suppliers

    test "suppliers index lists the user's suppliers A to Z with their url, item count and a Remove button" do
      zerex = @user.maker_suppliers.create!(name: "Zerex Supply")
      acme = @user.maker_suppliers.create!(name: "Acme Bolts", url: "https://acme.example.com")
      @user.maker_inventory_items.create!(name: "Bolt", supplier: acme)
      @user.maker_inventory_items.create!(name: "Washer", supplier: acme)

      get suppliers_path

      assert_response :success
      assert_select "h1", "Suppliers"
      names = css_select(".settings-list .settings-name").map { |el| el.text.strip }
      assert_equal [ "Acme Bolts", "Zerex Supply" ], names
      assert_select "a.settings-fact[href=?]", acme.url, text: acme.url
      assert_select ".settings-fact", text: "2 items"
      assert_select ".settings-fact", text: "0 items"
      assert_select "li form[action=?] button", supplier_path(acme), text: "Remove"
      assert_select "li form[action=?] button", supplier_path(zerex), text: "Remove"
    end

    test "an empty suppliers list still renders" do
      get suppliers_path

      assert_response :success
      assert_select "li.empty", text: "No suppliers yet."
    end

    # ASSERT THE RENDERED FIELD NAME (CLAUDE.md §14d) -- the form has no model object, so `scope:`
    # is the only thing naming its params at all; a POST of a Ruby hash (every other test below)
    # cannot see whether the real form would have produced those same names.
    test "the add form posts field names the controller reads" do
      get suppliers_path

      assert_select "form.settings-add input[name=?]", "supplier[name]"
      assert_select "form.settings-add input[name=?][type=url]", "supplier[url]"
    end

    test "creating a supplier redirects back with a flash" do
      post suppliers_path, params: { supplier: { name: "McMaster", url: "https://mcmaster.com" } }

      assert_redirected_to suppliers_path
      supplier = @user.maker_suppliers.find_by!(name: "McMaster")
      assert_equal "https://mcmaster.com", supplier.url
      assert_match(/mcmaster added/i, flash[:notice])
    end

    test "a blank supplier name is refused with the model's error, not a 500" do
      post suppliers_path, params: { supplier: { name: "" } }

      assert_redirected_to suppliers_path
      assert_match(/name can't be blank/i, flash[:alert])
      assert_empty @user.maker_suppliers
    end

    test "removing a supplier nullifies its items' supplier_id" do
      supplier = @user.maker_suppliers.create!(name: "Acme Bolts")
      item = @user.maker_inventory_items.create!(name: "Bolt", supplier: supplier)

      delete supplier_path(supplier)

      assert_redirected_to suppliers_path
      assert_match(/removed/i, flash[:notice])
      assert_nil Maker::Supplier.find_by(id: supplier.id)
      assert_nil item.reload.supplier_id
    end

    # MUTATION-CHECK (a): swapping the scoped lookup in SuppliersController#destroy for a bare
    # `Maker::Supplier.find(params[:id])` turns this from a 404 into a real delete of another
    # user's row.
    test "another user's supplier cannot be removed" do
      theirs = other_user!.maker_suppliers.create!(name: "Not yours")

      delete supplier_path(theirs)

      assert_response :not_found
      assert_predicate Maker::Supplier.find_by(id: theirs.id), :present?
    end

    # ============================================================ Locations

    test "locations index lists the user's locations A to Z with their parent, item count and a Remove button" do
      cabinet = @user.maker_locations.create!(name: "Cabinet B")
      drawer = @user.maker_locations.create!(name: "Drawer B1", parent: cabinet)
      @user.maker_inventory_items.create!(name: "Bolt", location: drawer)

      get locations_path

      assert_response :success
      assert_select "h1", "Locations"
      names = css_select(".settings-list .settings-name").map { |el| el.text.strip }
      assert_equal [ "Cabinet B", "Drawer B1" ], names
      assert_select ".settings-fact", text: "in Cabinet B"
      assert_select ".settings-fact", text: "1 item"
      assert_select "li form[action=?] button", location_path(drawer), text: "Remove"
    end

    test "an empty locations list still renders" do
      get locations_path

      assert_response :success
      assert_select "li.empty", text: "No locations yet."
    end

    test "the add form posts field names the controller reads, with a parent select" do
      @user.maker_locations.create!(name: "Cabinet B")

      get locations_path

      assert_select "form.settings-add input[name=?]", "location[name]"
      assert_select "form.settings-add select[name=?]", "location[parent_id]"
    end

    test "creating a location with a parent redirects back with a flash" do
      cabinet = @user.maker_locations.create!(name: "Cabinet B")

      post locations_path, params: { location: { name: "Drawer B1", parent_id: cabinet.id } }

      assert_redirected_to locations_path
      location = @user.maker_locations.find_by!(name: "Drawer B1")
      assert_equal cabinet.id, location.parent_id
      assert_match(/drawer b1 added/i, flash[:notice])
    end

    # A FOREIGN parent_id FAILS Maker::Location#parent_belongs_to_user, AND THE MODEL'S OWN MESSAGE
    # IS WHAT REACHES THE USER -- not a guessed one (the same argument Settings::ShelvesController#create's
    # comment makes for its own two-validation refusal).
    test "a foreign parent_id is refused with the model's error, not a 500" do
      theirs = other_user!.maker_locations.create!(name: "Not yours")

      post locations_path, params: { location: { name: "Drawer B1", parent_id: theirs.id } }

      assert_redirected_to locations_path
      assert_match(/parent must reference your own location/i, flash[:alert])
      assert_nil @user.maker_locations.find_by(name: "Drawer B1")
    end

    test "removing a location nullifies its children and items" do
      cabinet = @user.maker_locations.create!(name: "Cabinet B")
      drawer = @user.maker_locations.create!(name: "Drawer B1", parent: cabinet)
      item = @user.maker_inventory_items.create!(name: "Bolt", location: cabinet)

      delete location_path(cabinet)

      assert_redirected_to locations_path
      assert_nil Maker::Location.find_by(id: cabinet.id)
      assert_nil drawer.reload.parent_id
      assert_nil item.reload.location_id
    end

    # MUTATION-CHECK (a), THE LOCATIONS HALF: the identical unscoped-lookup swap in
    # LocationsController#destroy.
    test "another user's location cannot be removed" do
      theirs = other_user!.maker_locations.create!(name: "Not yours")

      delete location_path(theirs)

      assert_response :not_found
      assert_predicate Maker::Location.find_by(id: theirs.id), :present?
    end

    # ============================================================ Shell chrome

    test "both pages light the rail's Inventory link and link back to Inventory" do
      [ suppliers_path, locations_path ].each do |path|
        get path

        assert_select "aside.rail a.rail-link[aria-current='page'][href=?]", inventory_items_path
        assert_select ".page-head a[href=?]", inventory_items_path, text: "Inventory"
      end
    end

    # ============================================================ Query budget

    # THE count_queries IDIOM FROM page_query_budget_test.rb, copied rather than shared: this task
    # owns no file that class does, and the plan's own step 3 asks for this measurement to be
    # produced by THIS test file's own helper, with Task C adding the permanent
    # page_query_budget_test.rb entries later. SCHEMA/TRANSACTION and PRAGMA are excluded for the
    # identical reason that file gives: they are a page's cost only by accident of being first in
    # the process, and the warm-up request in each test below is what keeps them out regardless.
    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          n += 1
        end
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # MUTATION-CHECK (b): swap SuppliersController#index's one grouped `@item_counts` count for a
    # per-row `supplier.inventory_items.count` read in the view, and this goes from flat to +1
    # query per supplier -- reddening at 6 rows but not at 3.
    test "suppliers#index does not grow with the number of suppliers" do
      3.times { |i| @user.maker_suppliers.create!(name: "S#{i}") }
      get suppliers_path
      assert_response :success
      small = count_queries { get suppliers_path }

      3.times { |i| @user.maker_suppliers.create!(name: "S#{3 + i}") }
      get suppliers_path
      large = count_queries { get suppliers_path }

      assert_equal small, large,
                   "suppliers#index issued #{small} queries at 3 suppliers and #{large} at 6 -- " \
                   "it grows with the number of rows."
    end

    # THE LOCATIONS HALF OF MUTATION-CHECK (b), for LocationsController#index's identical shape
    # (plus its `includes(:parent)`).
    test "locations#index does not grow with the number of locations" do
      3.times { |i| @user.maker_locations.create!(name: "L#{i}") }
      get locations_path
      assert_response :success
      small = count_queries { get locations_path }

      3.times { |i| @user.maker_locations.create!(name: "L#{3 + i}") }
      get locations_path
      large = count_queries { get locations_path }

      assert_equal small, large,
                   "locations#index issued #{small} queries at 3 locations and #{large} at 6 -- " \
                   "it grows with the number of rows."
    end
  end
end
