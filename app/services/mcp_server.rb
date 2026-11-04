# frozen_string_literal: true

# THE MCP SERVER, BUILT PER REQUEST (McpController; spec docs/superpowers/specs/2026-11-04-mcp-server-design.md).
#
# One MCP::Server per POST, holding the tool classes and a server context of { user:, device: }: the
# SDK hands that context to every tool call, which is how a tool is scoped to the one account whose
# token authenticated the request (§8). Nothing is memoised across requests -- the tool classes are
# constants and the server object is a few hashes -- so there is no per-client state in the process
# and no cache keyed on less than the user (§14a's transport rule, in miniature).
#
# TOOLS ON THE MODELS, NEVER ON v1 OVER HTTP: a synchronous client pointed at this same Puma pool is
# the reentrancy §14e measured at 14-24 s stalls. Each tool calls the models and services the web
# layer calls, and answers in words a model can use (McpServer::Render).
module McpServer
  NAME = "tinkerex"
  VERSION = "1.0.0"

  # A slug, id or path that names nothing in THIS user's data (McpServer::Tool.project! and friends).
  # Answered as an isError tool result naming what was asked for -- never a hint about whether it
  # exists for someone else (§8).
  NotFound = Class.new(StandardError)
  # Client input the JSON schema cannot express as a rule: a path with `..`, a file that is not
  # text, a size over the read cap, the library root where a file was needed. The message is the
  # whole answer.
  Refused = Class.new(StandardError)

  INSTRUCTIONS = <<~TEXT.strip.freeze
    Tinkerex is this user's maker library: projects, tasks, a build log, inventory, bills of
    materials, and the files themselves. Every tool acts on the one account whose token you hold.
    Identify a project by its slug (list_projects gives it); a task, inventory item, BOM, BOM line,
    supplier or location by the numeric id a listing returns; a file or folder by its
    library-relative path such as "Projects/lamp/README.md" (list_folder with no path is the
    library root). Listings are capped and answer "truncated": true when they were cut; narrow with
    a query. Writes are real and nothing here undoes them: there is no delete tool, archive a
    project with update_project status "archived".
  TEXT

  # The catalog, in the order tools/list returns it. Each module lists its own classes in `all`.
  def self.tools
    [ Tools::Projects, Tools::Tasks, Tools::BuildLog, Tools::Inventory, Tools::Bom,
      Tools::Reference, Tools::Library ].flat_map(&:all)
  end

  def self.build(user:, device:)
    MCP::Server.new(name: NAME, version: VERSION, instructions: INSTRUCTIONS, tools: tools,
                    server_context: { user: user, device: device })
  end
end
