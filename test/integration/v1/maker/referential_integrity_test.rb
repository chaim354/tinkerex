require "test_helper"

module V1
  module Maker
    # DESTROYING A REFERENCED ROW MUST NOT LOCK THE ROWS THAT POINTED AT IT (audit A-M4).
    #
    # `InventoryItem` and `BomLine` run their `*_belongs_to_user` validations whenever the foreign
    # id is PRESENT, and a dangling id is present — so before the `dependent:` handling on
    # Supplier/Location/InventoryItem, a delete through these controllers refused every later save
    # of every referencing row, including edits to fields that have nothing to do with the
    # reference. Asserting the id went nil is the weak half; each test here follows it with a real
    # PATCH of an unrelated field, which is the behaviour a user notices.
    #
    # The companion to cross_tenant_fk_test.rb: that one proves a reference can't be CREATED across
    # tenants, this one proves destroying one side doesn't strand the other.
    class ReferentialIntegrityTest < ActionDispatch::IntegrationTest
      def register(email) = bootstrap_token(email: email, device_name: "d")
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register("ri@example.com")
        @user  = User.find_by(email: "ri@example.com")
      end

      def create_bom
        project = @user.maker_projects.create!(name: "Lamp")
        project.boms.create!(user: @user)
      end

      test "deleting a supplier leaves its inventory item editable" do
        sup = @user.maker_suppliers.create!(name: "Digikey")
        item = @user.maker_inventory_items.create!(name: "M3 bolt", supplier: sup)

        delete "/v1/maker/suppliers/#{sup.id}", headers: auth(@token)
        assert_response :no_content
        assert_nil item.reload.supplier_id

        patch "/v1/maker/inventory_items/#{item.id}",
              params: { inventory_item: { min_quantity: 25 } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal 25.0, JSON.parse(response.body)["min_quantity"].to_f
      end

      test "deleting a location leaves the items that sat there editable" do
        shelf = @user.maker_locations.create!(name: "Shelf A")
        item = @user.maker_inventory_items.create!(name: "M3 bolt", location: shelf)

        delete "/v1/maker/locations/#{shelf.id}", headers: auth(@token)
        assert_response :no_content
        assert_nil item.reload.location_id

        patch "/v1/maker/inventory_items/#{item.id}",
              params: { inventory_item: { name: "M3x10 bolt" } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "M3x10 bolt", JSON.parse(response.body)["name"]
      end

      test "deleting a supplier leaves its free-text BOM line editable" do
        sup = @user.maker_suppliers.create!(name: "Digikey")
        bom = create_bom
        line = bom.lines.create!(user: @user, part_name: "Generic LED", supplier_id: sup.id, quantity: 10)

        delete "/v1/maker/suppliers/#{sup.id}", headers: auth(@token)
        assert_response :no_content
        assert_nil line.reload.supplier_id

        patch "/v1/maker/bom_lines/#{line.id}",
              params: { bom_line: { quantity: 12 } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal 12.0, JSON.parse(response.body)["quantity"].to_f
      end

      test "deleting an inventory item leaves its BOM line as an editable free-text part" do
        item = @user.maker_inventory_items.create!(name: "M3 bolt")
        bom = create_bom
        line = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 4, reference: "B1")

        delete "/v1/maker/inventory_items/#{item.id}", headers: auth(@token)
        assert_response :no_content

        # The editability assertion comes first: a plain nullify would satisfy "the pointer is
        # gone" and still leave this PATCH refused, because the line would have no target at all.
        patch "/v1/maker/bom_lines/#{line.id}",
              params: { bom_line: { notes: "any hardware store" } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "any hardware store", JSON.parse(response.body)["notes"]

        line.reload
        assert_nil line.inventory_item_id
        assert_equal "M3 bolt", line.part_name, "the line must keep saying what part it needs"
        assert_equal "B1", line.reference
      end

      # WHY NO BACKFILL MIGRATION SHIPS WITH THIS FIX: rows already stranded before it are still
      # clearable by their owner through the same API, because the validations are guarded on the
      # id being present and clearing it skips them. Reproducing that state needs update_columns —
      # no controller can produce it any more.
      test "a reference stranded before this fix can still be cleared by its owner" do
        item = @user.maker_inventory_items.create!(name: "M3 bolt")
        item.update_columns(supplier_id: 999_999)

        patch "/v1/maker/inventory_items/#{item.id}",
              params: { inventory_item: { name: "still locked" } }, as: :json, headers: auth(@token)
        assert_response :unprocessable_entity

        patch "/v1/maker/inventory_items/#{item.id}",
              params: { inventory_item: { supplier_id: nil, name: "unlocked" } },
              as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "unlocked", item.reload.name
        assert_nil item.supplier_id
      end
    end
  end
end
