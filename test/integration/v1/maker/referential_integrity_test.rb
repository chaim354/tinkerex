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

      # THE `""` ARMS OF `release_bom_lines`' FILTER ARE REACHABLE THROUGH THE PUBLIC API, which is
      # the only reason they may exist. `exactly_one_target` counts with `present?`, so a create
      # carrying a BLANK part_name beside an inventory item is a perfectly valid one-target line:
      # the API accepts it and stores the blank rather than a NULL. Filter on nil alone and that
      # line comes out of the delete with `part_name: ""` and no target at all — 422 on every
      # subsequent save, which is A-M4 exactly. Driven end to end because the reachability is the
      # claim; a model-level test would have to plant the row it is trying to prove occurs.
      test "a BOM line whose part_name is blank rather than null still survives the delete" do
        item = @user.maker_inventory_items.create!(name: "M3 bolt")
        bom = create_bom

        post "/v1/maker/boms/#{bom.id}/bom_lines",
             params: { bom_line: { inventory_item_id: item.id, part_name: "", quantity: 4 } },
             as: :json, headers: auth(@token)
        assert_response :created
        line = @user.maker_bom_lines.find(JSON.parse(response.body)["id"])
        assert_equal "", line.part_name, "the API persists the blank; the \"\" arm exists for this row"

        delete "/v1/maker/inventory_items/#{item.id}", headers: auth(@token)
        assert_response :no_content

        # The unlock is the assertion that carries the weight, so it comes first.
        patch "/v1/maker/bom_lines/#{line.id}",
              params: { bom_line: { notes: "any hardware store" } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "any hardware store", JSON.parse(response.body)["notes"]
        assert_equal "free_text", JSON.parse(response.body)["target_kind"]
        assert_equal "M3 bolt", line.reload.part_name
      end

      # The other half of the same filter, equally reachable and equally fatal on its own: a blank
      # node_id is not a design-file target either, so a nil-only filter leaves this line targetless
      # too. Two arms, two tests, so a regression names which one broke.
      test "a BOM line whose node_id is blank rather than null still survives the delete" do
        item = @user.maker_inventory_items.create!(name: "M3 bolt")
        bom = create_bom

        post "/v1/maker/boms/#{bom.id}/bom_lines",
             params: { bom_line: { inventory_item_id: item.id, node_id: "", quantity: 4 } },
             as: :json, headers: auth(@token)
        assert_response :created
        line = @user.maker_bom_lines.find(JSON.parse(response.body)["id"])
        assert_equal "", line.node_id

        delete "/v1/maker/inventory_items/#{item.id}", headers: auth(@token)
        assert_response :no_content

        patch "/v1/maker/bom_lines/#{line.id}",
              params: { bom_line: { notes: "any hardware store" } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "M3 bolt", line.reload.part_name
      end

      # THE SAME SHAPE ONE MODEL OVER — `Maker::Item` had no `has_many :tasks` at all, so a deleted
      # item left every task that named it holding a dangling `taskable_id`, and
      # `Task#taskable_belongs_to_owner` (guarded on `taskable_id.present?`) then refused every
      # later save of that row. `:nullify` where the BOM line above needed a callback: `taskable`
      # is `optional: true` and nothing else refuses a task with no owner.
      #
      # THE PATCH IS THE ASSERTION THAT CARRIES THE WEIGHT, and it is the only half that can tell
      # the two handlers apart: `dependent: :destroy` satisfies "the pointer is nil" vacuously by
      # deleting the user's own to-do, and this request 404s instead of succeeding.
      test "deleting an item leaves the tasks that pointed at it editable" do
        item = @user.maker_items.create!(title: "Bracket")
        task = @user.maker_tasks.create!(title: "Print it", taskable: item)

        delete "/v1/maker/items/#{item.id}", headers: auth(@token)
        assert_response :no_content

        patch "/v1/maker/tasks/#{task.id}",
              params: { task: { title: "Print it in PETG" } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "Print it in PETG", JSON.parse(response.body)["title"]

        task.reload
        assert_nil task.taskable_id
        assert_nil task.taskable_type
      end

      # WHY NO BACKFILL MIGRATION SHIPS WITH THIS FIX: a row stranded before it is still recoverable
      # by its owner through the same API. Reproducing that state needs update_columns — no
      # controller can produce it any more. What recovery COSTS differs by column, and this test and
      # the next are the two shapes.
      #
      # On an inventory item it is free: the validations are guarded on the id being present, so
      # `PATCH { supplier_id: null }` skips them and saves.
      test "a stranded inventory-item reference can be cleared by its owner" do
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

      # On a BOM line it is NOT free, and "still clearable by their owner" is false as stated for
      # this column: clearing `inventory_item_id` on its own leaves the line with zero targets, so
      # `exactly_one_target` refuses it. The owner has to supply a REPLACEMENT target in the same
      # request — and has to remember the deleted item's name themselves, which is exactly what
      # `release_bom_lines` does for them from now on and cannot do retroactively.
      test "a stranded BOM-line reference needs a replacement target, not just a null" do
        bom = create_bom
        item = @user.maker_inventory_items.create!(name: "M3 bolt")
        line = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 4)
        line.update_columns(inventory_item_id: 999_999)

        patch "/v1/maker/bom_lines/#{line.id}",
              params: { bom_line: { notes: "still locked" } }, as: :json, headers: auth(@token)
        assert_response :unprocessable_entity

        patch "/v1/maker/bom_lines/#{line.id}",
              params: { bom_line: { inventory_item_id: nil } }, as: :json, headers: auth(@token)
        assert_response :unprocessable_entity, "clearing the pointer alone leaves no target"

        patch "/v1/maker/bom_lines/#{line.id}",
              params: { bom_line: { inventory_item_id: nil, part_name: "M3 bolt" } },
              as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "free_text", JSON.parse(response.body)["target_kind"]
      end
    end
  end
end
