require "test_helper"

module V1
  module Maker
    class InventoryItemsTest < ActionDispatch::IntegrationTest
      def register(email = "ii@example.com")
        bootstrap_token(email: email, device_name: "d")
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      def create_item(attrs = {}, token: @token)
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "M3 bolt" }.merge(attrs) },
             as: :json, headers: auth(token)
        JSON.parse(response.body)["id"]
      end

      test "create returns the item with a zero balance" do
        post "/v1/maker/inventory_items",
             params: { inventory_item: { name: "M3 bolt", unit: "each", min_quantity: 50 } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "M3 bolt", body["name"]
        assert_equal "0.0", body["quantity_cached"].to_s.sub(/\.0+\z/, ".0")
        assert_equal "50.0", body["min_quantity"].to_s.sub(/\.0+\z/, ".0")
      end

      test "adjust posts a transaction and moves the cached balance" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: 100, reason: "restocked" }, as: :json, headers: auth(@token)
        assert_response :created
        assert_equal 100.0, JSON.parse(response.body)["quantity_cached"].to_f

        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: -7, reason: "consumed" }, as: :json, headers: auth(@token)
        assert_equal 93.0, JSON.parse(response.body)["quantity_cached"].to_f
      end

      test "adjust rejects an invalid reason with 422" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: 1, reason: "bogus" }, as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      # WHAT A POSTABLE ROW IS BELONGS TO Maker::InventoryTransaction, SO THIS DOOR REFUSES WITH NO
      # LINE OF ITS OWN (V1::BaseController maps RecordInvalid to 422). It once lived in the web
      # controller alone, and here "1e400" and "0" answered 201: an Infinity row the immutable ledger
      # can never take back, and a row that records nothing. A JSON NUMBER 1e400 decodes to
      # Float::INFINITY and posted too. "Infinity"/"-Infinity"/"NaN" as strings were already refused
      # as not-a-number; they stay so the whole family is pinned at this door. The message is asserted
      # because the 422 must be the delta VALIDATION: none of these inputs raises ArgumentError on this
      # path, and since F-S18-1 V1::BaseController maps none, so one that did would be a 500.
      test "adjust answers 422 for a zero, non-finite or out-of-column delta and posts nothing" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: 12, reason: "initial" },
             as: :json, headers: auth(@token)
        assert_response :created

        # The delta exactly as it crosses the wire: five JSON strings, then two JSON numbers.
        [ '"Infinity"', '"-Infinity"', '"NaN"', '"1e400"', '"0"', "1e400", "-1e400" ].each do |wire|
          assert_no_difference -> { ::Maker::InventoryTransaction.count }, "delta #{wire} reached the ledger" do
            post "/v1/maker/inventory_items/#{id}/adjust", params: %({"delta": #{wire}, "reason": "restocked"}),
                 headers: auth(@token).merge("CONTENT_TYPE" => "application/json")
          end
          assert_response :unprocessable_entity, "delta #{wire}"
          assert_match(/\AValidation failed: Delta /, JSON.parse(response.body)["error"], "delta #{wire}")
        end
        assert_equal 12, ::Maker::InventoryItem.find(id).quantity_cached
      end

      # A PROJECT THAT IS NOT THE ITEM OWNER'S IS DROPPED, NOT REFUSED, AT THIS DOOR TOO. It was
      # stored as sent, and the poster's own ledger page then rendered that tenant's private project
      # name and linked its slug, so walking ids listed every tenant's projects. 200 is asserted
      # FIRST: a page that failed to render, or a sign-in that never took, is free of the name too.
      test "adjust drops another user's project, and the poster's ledger never names it" do
        poster = User.create!(email: "poster-#{SecureRandom.hex(4)}@example.com", password: WEB_PASSWORD,
                              confirmed_at: Time.current)
        token = register(poster.email)
        theirs = User.create!(email: "theirs-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                              omniauth_signup: true)
        foreign = theirs.maker_projects.create!(name: "Their Secret Lamp")
        id = create_item({}, token:)

        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: 5, reason: "restocked", project_id: foreign.id }, as: :json, headers: auth(token)
        assert_response :created
        assert_nil ::Maker::InventoryTransaction.where(inventory_item_id: id).sole.project_id

        sign_in_web!(poster)
        get inventory_item_path(id)
        assert_response :success
        assert_not_includes response.body, foreign.name
        assert_not_includes response.body, project_path(foreign)
      end

      test "transactions lists the ledger newest-first" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: 10, reason: "initial" },
             as: :json, headers: auth(@token)
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: -2, reason: "consumed" },
             as: :json, headers: auth(@token)
        get "/v1/maker/inventory_items/#{id}/transactions", headers: auth(@token)
        assert_response :success
        deltas = JSON.parse(response.body)["transactions"].map { |t| t["delta"].to_f }
        assert_equal [ -2.0, 10.0 ], deltas
      end

      test "low_stock returns items at or below min_quantity" do
        low = create_item({ name: "low", min_quantity: 10 })
        post "/v1/maker/inventory_items/#{low}/adjust", params: { delta: 3, reason: "initial" },
             as: :json, headers: auth(@token)
        ok = create_item({ name: "ok", min_quantity: 10 })
        post "/v1/maker/inventory_items/#{ok}/adjust", params: { delta: 99, reason: "initial" },
             as: :json, headers: auth(@token)
        get "/v1/maker/inventory_items/low_stock", headers: auth(@token)
        assert_response :success
        names = JSON.parse(response.body)["inventory_items"].map { |i| i["name"] }
        assert_includes names, "low"
        assert_not_includes names, "ok"
      end

      test "index is filterable by category" do
        create_item({ name: "bolt", category: "fasteners" })
        create_item({ name: "wire", category: "electronics" })
        get "/v1/maker/inventory_items", params: { category: "fasteners" }, headers: auth(@token)
        assert_equal [ "bolt" ], JSON.parse(response.body)["inventory_items"].map { |i| i["name"] }
      end

      test "another user cannot adjust my item" do
        id = create_item
        other = register("o@example.com")
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: 1, reason: "restocked" },
             as: :json, headers: auth(other)
        assert_response :not_found
      end

      test "auth is required" do
        get "/v1/maker/inventory_items"
        assert_response :unauthorized
      end
    end
  end
end
