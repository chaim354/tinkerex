# frozen_string_literal: true

# THE MCP SDK'S PROCESS-WIDE HOOKS (McpController; spec 2026-11-04-mcp-server-design §3, §7).
#
# exception_reporter: a tool that raises something McpServer::Tool.call does not map reaches here,
# and the SDK answers the client a JSON-RPC internal error (-32603) with no detail. The exception
# itself goes to Rails.error like any other handled error, so a tool bug is in the log and not only
# in the client's transcript. `handled: true` because the request still answered. The SDK hands the
# raw request as context; it is cut short because tool arguments can hold a whole note.
#
# validate_tool_call_arguments stays at the SDK's default (true): each tool's input_schema is checked
# before `call` runs, so a missing or misspelt argument is an isError result and never an
# ArgumentError out of a keyword signature (architecture_invariants_test: no controller rescues a
# bare ArgumentError, and none needs to).
MCP.configure do |config|
  config.exception_reporter = lambda do |exception, context|
    request = context.is_a?(Hash) ? context[:request].to_s.first(500) : nil
    Rails.error.report(exception, handled: true, source: "mcp", context: { mcp_request: request }.compact)
  end
end
