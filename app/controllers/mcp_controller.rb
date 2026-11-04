# frozen_string_literal: true

# POST /mcp -- THE MODEL CONTEXT PROTOCOL DOOR (spec docs/superpowers/specs/2026-11-04-mcp-server-design.md).
#
# STATELESS BY DESIGN. Each POST is one JSON-RPC message answered by McpServer.build's per-request
# server; no session id is minted, no SSE stream is held, no process memory outlives the request.
# That is what lets it run at any WEB_CONCURRENCY and is why the SDK's own Rack transport (sessions
# in one process, an allowed-hosts check that 403s every deployment hostname until listed) is not
# used. A client that probes GET for the stream gets 405 naming POST; DELETE, the spec's
# end-of-session, is 204 because there is nothing to end.
#
# THE CREDENTIAL IS THE DEVICE TOKEN, through V1::Authentication, exactly as /v1/maker/* (§8): a
# missing, unknown or idle-expired token is a 401 before a byte of body is read. The body is capped
# before parsing. A notification (the SDK answers nil) is 202 with no body, per the MCP transport
# spec.
#
# NO rescue_from HERE, DELIBERATELY. What a tool can raise is mapped once, in McpServer::Tool.call;
# anything else is a real 500 or the SDK's own -32603 (config/initializers/mcp.rb). In particular no
# bare ArgumentError is rescued (architecture_invariants_test.rb).
class McpController < ActionController::API
  include V1::Authentication

  MAX_BODY = 1.megabyte

  def create
    body = request.body.read(MAX_BODY + 1).to_s
    return head(413) if body.bytesize > MAX_BODY

    answer = McpServer.build(user: current_user, device: current_device).handle_json(body)
    return head(:accepted) if answer.nil?

    render json: answer
  end

  def show
    response.set_header("Allow", "POST")
    render json: { error: "method_not_allowed",
                   hint: "POST one JSON-RPC message to this URL with a device token as Bearer auth. " \
                         "This server keeps no session and streams nothing." },
           status: :method_not_allowed
  end

  def destroy = head(:no_content)
end
