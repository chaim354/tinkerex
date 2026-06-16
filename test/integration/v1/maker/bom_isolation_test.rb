require "test_helper"

module V1
  module Maker
    # Belt-and-suspenders: every BOM resource must 404 (never leak) across users.
    class BomIsolationTest < ActionDispatch::IntegrationTest
      def register(email)
        bootstrap_token(email: email, device_name: "d")
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-bomiso@example.com")
        @b = register("b-bomiso@example.com")
        post "/v1/maker/projects", params: { project: { name: "A's project" } }, as: :json, headers: auth(@a)
        @project = JSON.parse(response.body)["id"]
        post "/v1/maker/projects/#{@project}/boms", params: { bom: {} }, as: :json, headers: auth(@a)
        @bom = JSON.parse(response.body)["id"]
        post "/v1/maker/boms/#{@bom}/bom_lines", params: { bom_line: { node_id: "n", quantity: 1 } },
             as: :json, headers: auth(@a)
        @line = JSON.parse(response.body)["id"]
      end

      test "B cannot read, roll up, or mutate A's BOM and lines" do
        get    "/v1/maker/projects/#{@project}/boms", headers: auth(@b);                       assert_response :not_found
        get    "/v1/maker/boms/#{@bom}", headers: auth(@b);                                    assert_response :not_found
        get    "/v1/maker/boms/#{@bom}/rollup", headers: auth(@b);                             assert_response :not_found
        patch  "/v1/maker/boms/#{@bom}", params: { bom: { name: "hax" } }, as: :json, headers: auth(@b)
        assert_response :not_found
        delete "/v1/maker/boms/#{@bom}", headers: auth(@b);                                    assert_response :not_found
        get    "/v1/maker/boms/#{@bom}/bom_lines", headers: auth(@b);                          assert_response :not_found
        post   "/v1/maker/boms/#{@bom}/bom_lines", params: { bom_line: { node_id: "x", quantity: 1 } },
               as: :json, headers: auth(@b)
        assert_response :not_found
        delete "/v1/maker/bom_lines/#{@line}", headers: auth(@b);                              assert_response :not_found
      end
    end
  end
end
