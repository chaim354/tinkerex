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
    request = context.is_a?(Hash) ? context[:request].to_s.first(500).presence : nil
    Rails.error.report(exception, handled: true, source: "mcp", context: { mcp_request: request }.compact)
  end
end

# THE RACK GUARD IN FRONT OF /mcp (the door's review, 2026-11-04). Rails parses an application/json
# body into params BEFORE any controller callback runs: ActionController::Instrumentation reads
# request.filtered_parameters for its start-of-request payload and ParamsWrapper reads
# request.parameters, both ahead of before_action. Measured on the first version of this door: a
# 2 MiB body with no token was fully parsed before the 401, and every tool argument (a note's text,
# a file's path) appeared in the "Parameters:" log line, twice. So for POST /mcp this runs before
# the router and does two things:
#   * refuses a Content-Length over MAX_BODY with 413 before Rails reads a byte -- before
#     authentication too, which is the point: an unauthenticated body costs nothing to refuse;
#   * presets the request's parsed parameters to empty, the header ActionDispatch::Request#POST
#     consults first (its fetch_header), so nothing parses the body as params and the log line
#     carries only the route. McpController reads the raw body itself, bounded, after auth.
# A chunked body carries no Content-Length and is bounded by the controller's read instead.
# Defined here rather than under lib/ for the reason CloudflareOnly is (trusted_proxies.rb): an
# initializer cannot autoload an app or lib constant, and a middleware class is loaded once.
# Pinned by test/integration/mcp/protocol_test.rb ("never parsed as params", "refused before
# authentication").
class McpRequestGuard
  PATH = "/mcp".freeze
  MAX_BODY = 1.megabyte
  TOO_LARGE = [ 413, { "content-type" => "application/json", "cache-control" => "no-store" },
                [ { error: "content_too_large", max_bytes: MAX_BODY }.to_json ] ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["PATH_INFO"].to_s.chomp("/") == PATH
    return TOO_LARGE if env["CONTENT_LENGTH"].to_i > MAX_BODY

    # The same type Rails' own parse stores (an indifferent-access hash), so the route's symbol
    # keys merge in as strings exactly as they do on every other request.
    env["action_dispatch.request.request_parameters"] = ActiveSupport::HashWithIndifferentAccess.new
    @app.call(env)
  end
end

Rails.application.config.middleware.insert_before ActionDispatch::Executor, McpRequestGuard
