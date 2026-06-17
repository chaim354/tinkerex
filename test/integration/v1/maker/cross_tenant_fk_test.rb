require "test_helper"

module V1
  module Maker
    # Cross-tenant FK INJECTION: a controller permits a foreign-key param (supplier_id,
    # location_id, inventory_item_id, item_id…). A user must NOT be able to point one of
    # their records at ANOTHER user's record by passing a foreign id. The model-level
    # `*_belongs_to_user` validations are the defense; these assert it holds end-to-end
    # through the controllers.
    class CrossTenantFkTest < ActionDispatch::IntegrationTest
      def register(email) = bootstrap_token(email: email, device_name: "d")
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-fk@example.com")
        @b = register("b-fk@example.com")
        @a_user = User.find_by(email: "a-fk@example.com")
        @b_user = User.find_by(email: "b-fk@example.com")

        # B's private records that A must not be able to reference.
        @b_supplier = @b_user.maker_suppliers.create!(name: "B Supplier")
        @b_location = @b_user.maker_locations.create!(name: "B Shelf")
        @b_inv      = @b_user.maker_inventory_items.create!(name: "B Bolt")
      end

      test "A cannot create an inventory item referencing B's supplier" do
        post "/v1/maker/inventory_items",
             params: { inventory_item: { name: "Mine", supplier_id: @b_supplier.id } },
             as: :json, headers: auth(@a)
        assert_response :unprocessable_entity
        assert_equal 0, @a_user.maker_inventory_items.count
      end

      test "A cannot create an inventory item referencing B's location" do
        post "/v1/maker/inventory_items",
             params: { inventory_item: { name: "Mine", location_id: @b_location.id } },
             as: :json, headers: auth(@a)
        assert_response :unprocessable_entity
        assert_equal 0, @a_user.maker_inventory_items.count
      end

      test "A cannot update their inventory item to point at B's supplier" do
        mine = @a_user.maker_inventory_items.create!(name: "Mine")
        patch "/v1/maker/inventory_items/#{mine.id}",
              params: { inventory_item: { supplier_id: @b_supplier.id } },
              as: :json, headers: auth(@a)
        assert_response :unprocessable_entity
        assert_nil mine.reload.supplier_id
      end

      test "A cannot create a BOM line referencing B's inventory item" do
        project = @a_user.maker_projects.create!(name: "P")
        bom = project.boms.create!(user: @a_user)
        post "/v1/maker/boms/#{bom.id}/bom_lines",
             params: { bom_line: { inventory_item_id: @b_inv.id, quantity: 1 } },
             as: :json, headers: auth(@a)
        assert_response :unprocessable_entity
        assert_equal 0, bom.lines.count
      end

      test "A cannot create a BOM line referencing B's supplier (free-text part)" do
        project = @a_user.maker_projects.create!(name: "P2")
        bom = project.boms.create!(user: @a_user)
        post "/v1/maker/boms/#{bom.id}/bom_lines",
             params: { bom_line: { part_name: "Widget", supplier_id: @b_supplier.id, quantity: 1 } },
             as: :json, headers: auth(@a)
        assert_response :unprocessable_entity
        assert_equal 0, bom.lines.count
      end

      test "A cannot update their BOM line to point at B's inventory item" do
        project = @a_user.maker_projects.create!(name: "P3")
        bom = project.boms.create!(user: @a_user)
        line = bom.lines.create!(user: @a_user, node_id: "n", quantity: 1)
        patch "/v1/maker/bom_lines/#{line.id}",
              params: { bom_line: { inventory_item_id: @b_inv.id, node_id: nil } },
              as: :json, headers: auth(@a)
        assert_response :unprocessable_entity
        assert_nil line.reload.inventory_item_id
      end
    end
  end
end
