require "test_helper"

module V1
  module Maker
    class BomLinesTest < ActionDispatch::IntegrationTest
      def register(email = "bl@example.com")
        bootstrap_token(email: email, device_name: "d")
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        @project = JSON.parse(response.body)["id"]
        post "/v1/maker/projects/#{@project}/boms", params: { bom: {} }, as: :json, headers: auth(@token)
        @bom = JSON.parse(response.body)["id"]
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "M3 bolt" } },
             as: :json, headers: auth(@token)
        @inv = JSON.parse(response.body)["id"]
        post "/v1/maker/inventory_items/#{@inv}/adjust", params: { delta: 40, reason: "initial" },
             as: :json, headers: auth(@token)
      end

      test "add an inventory-item line" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { inventory_item_id: @inv, quantity: 4, reference: "B1" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal @inv, body["inventory_item_id"]
        assert_equal "inventory_item", body["target_kind"]
      end

      test "add a design-file line by node_id" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { node_id: "node-step", quantity: 1 } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "design_file", JSON.parse(response.body)["target_kind"]
      end

      test "add a free-text part line" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { part_name: "Generic LED", quantity: 10 } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "free_text", JSON.parse(response.body)["target_kind"]
      end

      test "a line with two targets is rejected with 422" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { inventory_item_id: @inv, node_id: "n", quantity: 1 } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "a line with no target is rejected with 422" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { quantity: 1 } }, as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "index lists a BOM's lines; update and destroy a line" do
        post "/v1/maker/boms/#{@bom}/bom_lines", params: { bom_line: { node_id: "n1", quantity: 1 } },
             as: :json, headers: auth(@token)
        line = JSON.parse(response.body)["id"]
        get "/v1/maker/boms/#{@bom}/bom_lines", headers: auth(@token)
        assert_equal 1, JSON.parse(response.body)["bom_lines"].size
        patch "/v1/maker/bom_lines/#{line}", params: { bom_line: { quantity: 5, reference: "X" } },
              as: :json, headers: auth(@token)
        assert_equal 5.0, JSON.parse(response.body)["quantity"].to_f
        delete "/v1/maker/bom_lines/#{line}", headers: auth(@token)
        assert_response :no_content
      end

      test "rollup resolves every line's target" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { inventory_item_id: @inv, quantity: 4 } }, as: :json, headers: auth(@token)
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { part_name: "Generic LED", quantity: 10 } }, as: :json, headers: auth(@token)
        get "/v1/maker/boms/#{@bom}/rollup", headers: auth(@token)
        assert_response :success
        lines = JSON.parse(response.body)["lines"]
        inv_line = lines.find { |l| l["target_kind"] == "inventory_item" }
        assert_equal 40.0, inv_line["target"]["inventory_item"]["quantity_cached"].to_f
        free_line = lines.find { |l| l["target_kind"] == "free_text" }
        assert_equal "Generic LED", free_line["target"]["part_name"]
      end

      test "cannot link another user's inventory item (422)" do
        other = register("o@example.com")
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "Theirs" } },
             as: :json, headers: auth(other)
        foreign = JSON.parse(response.body)["id"]
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { inventory_item_id: foreign, quantity: 1 } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "cannot add a line to another user's BOM (404)" do
        other = register("o2@example.com")
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { node_id: "n", quantity: 1 } }, as: :json, headers: auth(other)
        assert_response :not_found
      end
    end
  end
end
