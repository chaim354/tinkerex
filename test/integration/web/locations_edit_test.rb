require "test_helper"

module Web
  # LOCATIONS CAN BE RENAMED, RE-PLACED AND ANNOTATED, AND A REFUSAL KEEPS WHAT WAS TYPED (UX audit
  # 2026-11-01, E5 and B3), as Suppliers can (suppliers_edit_test.rb). The notes column is
  # `description`; the forms call it Notes. Re-placing is what makes a cycle reachable, so the edit
  # page offers no parent inside the location and Maker::Location refuses a crafted one.
  #
  # No library involvement: these pages read and write Maker::* rows only.
  class LocationsEditTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "loc-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
      @cabinet = @user.maker_locations.create!(name: "Cabinet B")
      @drawer = @user.maker_locations.create!(name: "Drawer B1", parent: @cabinet)
      @tray = @user.maker_locations.create!(name: "Tray", parent: @drawer)
      @shelf = @user.maker_locations.create!(name: "Shelf")
    end

    test "the list's crumbs say Inventory › Locations, with no ghost button named for the parent" do
      get locations_path
      assert_select "title", text: "Locations — Tinkerex"
      assert_select "header.topbar nav.breadcrumb a[href=?]", inventory_items_path, text: "Inventory"
      assert_select "header.topbar nav.breadcrumb [aria-current='page']", text: "Locations"
      assert_select ".page-head a[href=?]", inventory_items_path, count: 0
      assert_no_match(/ -- /, css_select("main").text)
      assert_select "form.settings-add input[name='location[description]']"
    end

    test "the edit page offers every parent except the location and what is inside it" do
      get edit_location_path(@cabinet)
      assert_response :success
      assert_select "form[action=?]", location_path(@cabinet) do
        assert_select "input[name='location[name]'][value='Cabinet B']"
        assert_select "textarea[name='location[description]']"
        options = css_select("select[name='location[parent_id]'] option").map(&:text)
        assert_equal [ "— none —", "Shelf" ], options
      end
    end

    test "a rename, a new parent and notes save" do
      patch location_path(@drawer), params: { location: { name: "Drawer 1", parent_id: @shelf.id, description: "Left side" } }
      assert_redirected_to locations_path
      assert_equal "Saved Drawer 1.", flash[:notice]
      @drawer.reload
      assert_equal [ "Drawer 1", @shelf.id, "Left side" ], [ @drawer.name, @drawer.parent_id, @drawer.description ]
    end

    # THE DOOR'S OWN ANSWER TO A CRAFTED CYCLE: the page offers no such parent, so only a hand-built
    # post reaches this, and the model refuses it rather than storing a ring every "in X" walks round.
    test "a location cannot be put inside itself or inside what it holds" do
      [ @cabinet.id, @tray.id ].each do |inside|
        patch location_path(@cabinet), params: { location: { name: "Cabinet B", parent_id: inside } }
        assert_response :unprocessable_entity
        assert_select ".form-errors", text: /Parent cannot be this location or one inside it/
      end
      assert_nil @cabinet.reload.parent_id
    end

    test "a refused add re-renders the list with the error and keeps the typed parent and notes" do
      theirs = User.create!(email: "loc-o-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                            omniauth_signup: true).maker_locations.create!(name: "Not yours")
      assert_no_difference -> { @user.maker_locations.count } do
        post locations_path, params: { location: { name: "", parent_id: @shelf.id, description: "Top" } }
      end
      assert_response :unprocessable_entity
      assert_select "form.settings-add .form-errors", text: /Name can't be blank/
      assert_select "form.settings-add select[name='location[parent_id]'] option[selected][value=?]", @shelf.id.to_s
      assert_select "form.settings-add input[name='location[description]'][value='Top']"

      post locations_path, params: { location: { name: "Bin", parent_id: theirs.id } }
      assert_response :unprocessable_entity
      assert_select "form.settings-add .form-errors", text: /Parent must reference your own location/
      assert_select "form.settings-add input[name='location[name]'][value='Bin']"
    end

    test "another user's location cannot be opened or renamed" do
      theirs = User.create!(email: "loc-p-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                            omniauth_signup: true).maker_locations.create!(name: "Not yours")
      get edit_location_path(theirs)
      assert_response :not_found
      patch location_path(theirs), params: { location: { name: "Mine now" } }
      assert_response :not_found
    end
  end
end
