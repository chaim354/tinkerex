# frozen_string_literal: true

# DRIVES POST /mcp THE WAY A CLIENT DOES, over the real device token and the real controller. Every
# MCP test includes this rather than building JSON-RPC by hand, so the wire shape is written once.
module McpClient
  def mcp_headers(token) = { "Authorization" => "Bearer #{token}" }

  # A Hash is sent as JSON; a String is sent raw (for the malformed-body and oversize tests).
  def mcp_post(token, body)
    if body.is_a?(String)
      post "/mcp", params: body, headers: mcp_headers(token).merge("CONTENT_TYPE" => "application/json")
    else
      post "/mcp", params: body, as: :json, headers: mcp_headers(token)
    end
  end

  def mcp_rpc(token, method, params = nil, id: 1)
    message = { jsonrpc: "2.0", id: id, method: method }
    message[:params] = params unless params.nil?
    mcp_post(token, message)
    assert_response :success, "#{method} answered #{response.status}: #{response.body.first(300)}"
    JSON.parse(response.body)
  end

  # tools/call's result hash (content, isError, structuredContent). A JSON-RPC error fails the test.
  def mcp_tool(token, name, arguments = {})
    body = mcp_rpc(token, "tools/call", { name: name, arguments: arguments })
    body.fetch("result") { flunk "#{name}: JSON-RPC error #{body["error"].inspect}" }
  end

  def mcp_structured(token, name, arguments = {})
    result = mcp_tool(token, name, arguments)
    refute result["isError"], "#{name} refused: #{result.dig("content", 0, "text")}"
    result.fetch("structuredContent")
  end

  def mcp_refusal(token, name, arguments = {})
    result = mcp_tool(token, name, arguments)
    assert result["isError"], "#{name} was expected to refuse but answered #{result.inspect.first(300)}"
    result.dig("content", 0, "text")
  end

  # The house stub helper (markdown_file_page_test.rb carries the same body; Minitest 6 has no
  # Object#stub). Replaces a SINGLETON method for the block, removing an inherited one after.
  def replacing(owner, name, replacement)
    mod = owner.singleton_class
    own = mod.instance_methods(false).include?(name)
    original = mod.instance_method(name)
    mod.define_method(name, &replacement)
    yield
  ensure
    own ? mod.define_method(name, original) : mod.remove_method(name)
  end
end
