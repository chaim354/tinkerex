require "test_helper"

module V1
  module Maker
    class BomsTest < ActionDispatch::IntegrationTest
      def register(email = "b@example.com")
        bootstrap_token(email: email, device_name: "d")
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        @project = JSON.parse(response.body)["id"]
      end

      test "create a BOM under a project" do
        post "/v1/maker/projects/#{@project}/boms",
             params: { bom: { name: "Main BOM", revision: 1 } }, as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Main BOM", body["name"]
        assert_equal 1, body["revision"]
        assert_equal @project, body["project_id"]
      end

      test "create defaults name and revision" do
        post "/v1/maker/projects/#{@project}/boms", params: {}, as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "BOM", body["name"]
        assert_equal 1, body["revision"]
      end

      test "index lists a project's BOM revisions" do
        post "/v1/maker/projects/#{@project}/boms", params: { bom: { revision: 1 } }, as: :json, headers: auth(@token)
        post "/v1/maker/projects/#{@project}/boms", params: { bom: { revision: 2 } }, as: :json, headers: auth(@token)
        get "/v1/maker/projects/#{@project}/boms", headers: auth(@token)
        assert_response :success
        assert_equal [ 1, 2 ], JSON.parse(response.body)["boms"].map { |b| b["revision"] }.sort
      end

      test "show, update, and destroy a BOM" do
        post "/v1/maker/projects/#{@project}/boms", params: { bom: { name: "v1" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        get "/v1/maker/boms/#{id}", headers: auth(@token)
        assert_response :success
        patch "/v1/maker/boms/#{id}", params: { bom: { name: "v1-final", revision: 2 } },
              as: :json, headers: auth(@token)
        assert_equal "v1-final", JSON.parse(response.body)["name"]
        assert_equal 2, JSON.parse(response.body)["revision"]
        delete "/v1/maker/boms/#{id}", headers: auth(@token)
        assert_response :no_content
      end

      # An explicit `{"bom": null}` used to raise `NoMethodError: undefined method 'permit' for
      # nil` — an UNRESCUED 500, the only one in the v1 maker controllers. `fetch`'s default fires
      # on absence only, so the null went straight to `.permit`. 400 is what every sibling
      # body-param controller already answers for this input; see `#bom_params`' comment for why
      # not 422. Driven as a real request because that is the only thing that can see it.
      test "an explicit null bom is a 400, not an unrescued 500" do
        post "/v1/maker/projects/#{@project}/boms",
             params: { bom: nil }, as: :json, headers: auth(@token)
        assert_response :bad_request
        assert_match(/bom/, JSON.parse(response.body)["error"])
      end

      # The other half of the same line, and the reason `require(:bom)` outright is the wrong
      # fix: a BOM needs no attributes, so an absent key must keep creating a defaulted one.
      test "a bodyless create still makes a defaulted BOM" do
        post "/v1/maker/projects/#{@project}/boms", as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "BOM", body["name"]
        assert_equal 1, body["revision"]
      end

      test "cannot create a BOM under another user's project" do
        other = register("o@example.com")
        post "/v1/maker/projects/#{@project}/boms", params: { bom: {} }, as: :json, headers: auth(other)
        assert_response :not_found
      end
    end
  end
end
