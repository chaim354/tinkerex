require "test_helper"
require "support/mcp_client"

module Mcp
  # THE WIRE, WITHOUT ANY TOOL: the handshake, the three verbs, the credential gate and the body
  # cap. Tool behaviour is the per-module files beside this one; the catalog itself is
  # catalog_test.rb.
  class ProtocolTest < ActionDispatch::IntegrationTest
    include McpClient

    setup { @token = bootstrap_token(email: "mcp-protocol@example.com", device_name: "assistant") }

    test "initialize answers the server's name, its instructions and the tools capability" do
      body = mcp_rpc(@token, "initialize", { protocolVersion: "2025-11-25", capabilities: {},
                                             clientInfo: { name: "test", version: "0" } })
      assert_equal "tinkerex", body.dig("result", "serverInfo", "name")
      assert_equal "2025-11-25", body.dig("result", "protocolVersion")
      assert body.dig("result", "capabilities").key?("tools"), body.inspect
      assert_includes body.dig("result", "instructions"), "slug"
    end

    test "a notification answers 202 with no body" do
      mcp_post(@token, { jsonrpc: "2.0", method: "notifications/initialized" })
      assert_response :accepted
      assert_empty response.body
    end

    test "ping answers an empty result" do
      assert_equal({}, mcp_rpc(@token, "ping")["result"])
    end

    test "tools/list names exactly what the catalog declares, in its order" do
      names = mcp_rpc(@token, "tools/list").dig("result", "tools").map { |t| t["name"] }
      assert_equal McpServer.tools.map(&:name_value), names
    end

    test "no token, a wrong token and an idle-expired token each answer 401 before any JSON-RPC runs" do
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "ping" }, as: :json
      assert_response :unauthorized
      mcp_post("not-a-token", { jsonrpc: "2.0", id: 1, method: "ping" })
      assert_response :unauthorized
      Device.find_by!(token_digest: Device.digest(@token)).update_column(:last_seen_at, (Device::IDLE_DAYS_DEFAULT + 1).days.ago)
      mcp_post(@token, { jsonrpc: "2.0", id: 1, method: "ping" })
      assert_response :unauthorized
    end

    test "GET answers 405 naming POST, and DELETE answers 204" do
      get "/mcp", headers: mcp_headers(@token)
      assert_response :method_not_allowed
      assert_equal "POST", response.headers["Allow"]
      assert_equal "method_not_allowed", JSON.parse(response.body)["error"]
      delete "/mcp", headers: mcp_headers(@token)
      assert_response :no_content
    end

    test "a body over the cap answers 413 before parsing" do
      mcp_post(@token, "{\"pad\":\"#{"x" * (McpController::MAX_BODY + 1)}\"}")
      assert_response 413
    end

    # THE TWO THINGS McpRequestGuard EXISTS FOR (config/initializers/mcp.rb). Rails parses a JSON body
    # into params before any callback; measured on the first version of this door, a 2 MiB body with
    # no token was parsed in full before the 401 and every tool argument reached the log line.
    test "an oversized body is refused before authentication, not parsed and then 401'd" do
      post "/mcp", params: "{\"pad\":\"#{"x" * (McpController::MAX_BODY + 1)}\"}",
                   headers: { "CONTENT_TYPE" => "application/json" }
      assert_response 413
      assert_equal "content_too_large", JSON.parse(response.body)["error"]
    end

    test "the body is never parsed as params, so a tool argument never reaches the request log" do
      seen = nil
      sub = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*, payload|
        seen = payload[:params] if payload[:controller] == "McpController"
      end
      body = mcp_rpc(@token, "tools/call", { name: "no_such_tool", arguments: { note: "secret-note-text" } })
      assert_equal(-32602, body.dig("error", "code"), "the body still reached the SDK")
      assert_equal %w[action controller], seen.keys.sort,
                   "the controller saw the body as params: #{seen.inspect.first(200)}"
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    test "a malformed body is a JSON-RPC parse error, not a 500" do
      mcp_post(@token, "{not json")
      assert_response :success
      assert_equal(-32700, JSON.parse(response.body).dig("error", "code"))
    end

    test "an unknown method is a JSON-RPC method-not-found" do
      assert_equal(-32601, mcp_rpc(@token, "no/such/method").dig("error", "code"))
    end
  end
end
