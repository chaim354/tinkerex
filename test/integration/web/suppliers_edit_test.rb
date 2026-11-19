require "test_helper"

module Web
  # SUPPLIERS CAN BE RENAMED AND KEEP NOTES, AND A REFUSAL KEEPS WHAT WAS TYPED (UX audit 2026-11-01,
  # E5 and B3). They could only be added and removed, the notes column had no field, a refused add
  # redirected with an alert and dropped the input, and the head carried an "Inventory" ghost button
  # where the breadcrumb belongs (A4/F8). settings_reference_test.rb has the list and Remove.
  #
  # No library involvement: these pages read and write Maker::* rows only.
  class SuppliersEditTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "sup-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
      @supplier = @user.maker_suppliers.create!(name: "McMaster", url: "https://mcmaster.com")
    end

    test "the list's crumbs say Inventory › Suppliers, and there is no ghost button named for the parent" do
      get suppliers_path
      assert_select "title", text: "Suppliers — Tinkerex"
      assert_select "header.topbar nav.breadcrumb a[href=?]", inventory_items_path, text: "Inventory"
      assert_select "header.topbar nav.breadcrumb [aria-current='page']", text: "Suppliers"
      assert_select ".page-head a[href=?]", inventory_items_path, count: 0
      assert_no_match(/ -- /, css_select("main").text, "prose uses an em dash, never a double hyphen")
      assert_select "li a.linkbtn[href=?]", edit_supplier_path(@supplier), text: "Edit"
    end

    test "the edit page renders the field names the controller reads" do
      get edit_supplier_path(@supplier)
      assert_response :success
      assert_select "title", text: "Edit McMaster — Tinkerex"
      assert_select "header.topbar nav.breadcrumb a[href=?]", suppliers_path, text: "Suppliers"
      assert_select "aside.rail a.rail-link[aria-current='page'][href=?]", inventory_items_path
      assert_select "form[action=?]", supplier_path(@supplier) do
        assert_select "input[name='_method'][value='patch']"
        assert_select "input[name='supplier[name]'][value='McMaster']"
        assert_select "input[name='supplier[url]'][type=url]"
        assert_select "textarea[name='supplier[notes]']"
      end
    end

    test "a rename and its notes save" do
      patch supplier_path(@supplier), params: { supplier: { name: "McMaster-Carr", notes: "Next-day to the shop." } }
      assert_redirected_to suppliers_path
      assert_equal "Saved McMaster-Carr.", flash[:notice]
      assert_equal [ "McMaster-Carr", "Next-day to the shop." ], @supplier.reload.slice(:name, :notes).values

      get suppliers_path
      assert_select "li .settings-name", text: "McMaster-Carr"
      assert_select "li .settings-note", text: "Next-day to the shop."
    end

    test "a refused rename re-renders the edit page with the error and the typed notes" do
      patch supplier_path(@supplier), params: { supplier: { name: "", notes: "Keep this" } }
      assert_response :unprocessable_entity
      assert_select ".form-errors.flash-alert", text: /Name can't be blank/
      assert_select "textarea[name='supplier[notes]']", text: "Keep this"
      # The crumbs and title name the supplier as it is saved, not the blank that was refused.
      assert_select "header.topbar nav.breadcrumb [aria-current='page']", text: "McMaster"
      assert_equal "McMaster", @supplier.reload.name
    end

    test "a refused add re-renders the list with the error and keeps the typed URL and notes" do
      assert_no_difference -> { @user.maker_suppliers.count } do
        post suppliers_path, params: { supplier: { name: "", url: "https://digikey.com", notes: "Parts" } }
      end
      assert_response :unprocessable_entity
      assert_select "form.settings-add .form-errors", text: /Name can't be blank/
      assert_select "form.settings-add input[name='supplier[url]'][value='https://digikey.com']"
      assert_select "form.settings-add input[name='supplier[notes]'][value='Parts']"
      # The list still lists, under the refused form.
      assert_select "li .settings-name", text: "McMaster"
    end

    test "another user's supplier cannot be opened or renamed" do
      theirs = User.create!(email: "sup-o-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                            omniauth_signup: true).maker_suppliers.create!(name: "Not yours")
      get edit_supplier_path(theirs)
      assert_response :not_found
      patch supplier_path(theirs), params: { supplier: { name: "Mine now" } }
      assert_response :not_found
      assert_equal "Not yours", theirs.reload.name
    end
  end
end
