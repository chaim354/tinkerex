# MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` governs dispatch**: batch by file, run independent tasks in parallel, no spec-compliance stage, one capped quality review per task.

**Goal:** Tinkerex serves a Model Context Protocol endpoint at `POST /mcp` so an AI client can read and change a user's projects, tasks, build log, inventory and BOMs and browse the library's folders and text files, with a token minted on Settings → Devices.

**Architecture:** A stateless `McpController` (`ActionController::API` + the existing `V1::Authentication` Bearer device-token concern) hands each JSON-RPC body to an `MCP::Server` built per request from the official `mcp` gem, with `{ user:, device: }` as the server context. Twenty-one `MCP::Tool` subclasses under `McpServer::Tools::*` call the same models and services the web layer uses; one `Render` module shapes rows for an LLM; one `LibraryPath` module turns library-relative paths into nodes. No sessions, no SSE, no deletes.

**Tech Stack:** Rails 8.1, the `mcp` gem 1.9 (Apache-2.0; dep `json_schemer`, MIT), Minitest integration tests driving the real endpoint.

**Spec:** `docs/superpowers/specs/2026-11-04-mcp-server-design.md`. Read it first; this plan implements it section by section.

---

## File map

| file | task | responsibility |
|---|---|---|
| `Gemfile`, `Gemfile.lock` | 1 | the `mcp` gem |
| `config/initializers/mcp.rb` | 1 | SDK exception reporter → `Rails.error` |
| `config/routes.rb` | 1, 8 | `/mcp` (three verbs); `settings/devices#create` |
| `app/controllers/mcp_controller.rb` | 1 | the HTTP door |
| `app/services/mcp_server.rb` | 1 | `McpServer.build`, the catalog order, `NotFound`/`Refused`, the instructions text |
| `app/services/mcp_server/tool.rb` | 1 | the tool base: context, annotations, finders, the error map |
| `app/services/mcp_server/render.rb` | 1 | the one place rows are shaped |
| `app/services/mcp_server/library_path.rb` | 1 | path ⇄ node |
| `app/services/mcp_server/tools/{projects,tasks,build_log,inventory,bom,reference,library}.rb` | 1 (stubs), 2–7 (bodies) | the 24 tools |
| `test/support/mcp_client.rb` | 1 | drives `/mcp` in tests; the `replacing` stub |
| `test/integration/mcp/protocol_test.rb` | 1 | handshake, 401/405/413, parse error |
| `test/integration/mcp/{projects,tasks,inventory,bom,reference,library}_tools_test.rb` | 2–7 | one file per tools module |
| `app/controllers/settings/devices_controller.rb`, `app/views/settings/devices/{index,connected}.html.erb`, `app/assets/stylesheets/pages/settings.css` | 8 | the token door |
| `test/integration/web/settings_devices_connect_test.rb` | 8 | the token door's test |
| `docs/mcp.md` | 9 | user docs |
| `test/integration/mcp/{catalog,isolation,query_budget}_test.rb`, `CLAUDE.md`, `test/docs_hygiene_test.rb` | 10 | the cross-cutting guards and the invariant |

## Dispatch order

- **Wave 1: Task 1 alone.** Everything else needs its base class, controller and test helper.
- **Wave 2, in parallel, disjoint paths:** Tasks 2, 3, 4, 5, 6, 7, 8, 9. Each owns its own source file(s) and test file(s) and touches nothing else. Task 8 is the only one that edits `config/routes.rb` after Task 1, and it edits only the `namespace :settings` block.
- **Wave 3: Task 10** after every Wave 2 task has landed (it pins the full catalog).
- **Task 11** is the close-out: `bin/ci`, the live check, `/finish-branch`, `bin/log arc`.

**Rules for every implementer in this worktree** (`/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/mcp-server`, branch `claude/mcp-server`):
- Write files; **do not commit** — the orchestrator commits each task by pathspec (parallel agents race on the git index). Never `git checkout --`, `git stash` or `git add -A`.
- Run tests with your own database and library so parallel runs do not collide:
  ```bash
  export DATABASE_URL=sqlite3:storage/test_<task>.sqlite3 LIBRARY_BACKEND=share LIBRARY_PATH=/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/mcp-server/tmp/lib_<task>
  mkdir -p "$LIBRARY_PATH" && bin/rails db:test:prepare
  bin/rails test test/integration/mcp/<file>_test.rb
  ```
  (`<task>` is your task number.) Bare `bin/rails test` without `LIBRARY_PATH` errors 187 times and proves nothing.
- Style is `bin/rubocop` (omakase): double quotes, `[ a, b ]` with spaces inside array brackets, `{ a: 1 }`. Run `bin/rubocop <your files>` before reporting.
- Every guard you write gets mutation-checked (CLAUDE.md §15): break the thing it guards, see red, restore with the file tools (never `git checkout`), report the actual output.
- No emoji anywhere (`test/no_emoji_test.rb`). In ERB comments never write `%>` or `<%=` (`template_hygiene_test.rb`).

---

### Task 1: Foundation — gem, server, tool base, render, paths, controller, route, protocol test

**Files:**
- Modify: `Gemfile` (after `gem "aws-sdk-s3", require: false`), `Gemfile.lock` (via `bundle install`)
- Create: `config/initializers/mcp.rb`
- Create: `app/services/mcp_server.rb`
- Create: `app/services/mcp_server/tool.rb`
- Create: `app/services/mcp_server/render.rb`
- Create: `app/services/mcp_server/library_path.rb`
- Create: `app/services/mcp_server/tools/projects.rb`, `tasks.rb`, `build_log.rb`, `inventory.rb`, `bom.rb`, `reference.rb`, `library.rb` (stubs; Wave 2 fills them)
- Create: `app/controllers/mcp_controller.rb`
- Modify: `config/routes.rb` (immediately before `namespace :v1 do`)
- Create: `test/support/mcp_client.rb`
- Create: `test/integration/mcp/protocol_test.rb`

- [ ] **Step 1: Add the gem**

In `Gemfile`, after the `aws-sdk-s3` line:

```ruby
# The MCP server at POST /mcp (McpController; docs/superpowers/specs/2026-11-04-mcp-server-design.md).
# The official SDK, Apache-2.0 (§9); its one runtime dependency, json_schemer, is MIT. Only the
# JSON-RPC server half is used: the HTTP door is this app's own controller, so the gem's Rack
# transport (and its sessions, SSE streams and allowed-hosts check) is never loaded.
gem "mcp", "~> 1.9"
```

Run: `bundle install`
Expected: `Gemfile.lock` gains `mcp (1.9.0)` and `json_schemer`. `bundle exec ruby -e 'require "mcp"; puts MCP::VERSION'` prints `1.9.0`.

- [ ] **Step 2: The initializer**

Create `config/initializers/mcp.rb`:

```ruby
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
```

- [ ] **Step 3: The server namespace**

Create `app/services/mcp_server.rb`:

```ruby
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
```

- [ ] **Step 4: The tool base**

Create `app/services/mcp_server/tool.rb`:

```ruby
# frozen_string_literal: true

module McpServer
  # THE BASE OF EVERY TOOL (spec docs/superpowers/specs/2026-11-04-mcp-server-design.md §3, §7).
  #
  # A subclass declares `tool_name`, `description`, `input_schema` (ALWAYS with
  # `additionalProperties: false`, so a misspelt argument is refused by the SDK as an isError result
  # instead of reaching `perform` as an unknown keyword), one of `reads!` / `writes!`, and
  # `self.perform(user, **args)`. `call` below is the SDK's entry and the one door: it reads the
  # user off the server context McpController built, runs `perform`, and maps what a tool can raise
  # to isError results (§7). Everything else propagates to the SDK, which answers a JSON-RPC internal
  # error and reports the exception (config/initializers/mcp.rb). NOTHING HERE RESCUES
  # NotImplementedError (§14a): it is a ScriptError and the rescue list below never names it.
  #
  # ANNOTATIONS ARE STATED IN FULL because the SDK's defaults are `destructive_hint: true` and
  # `open_world_hint: true` (MCP::Tool::Annotations): a read tool that forgot `reads!` would be
  # presented to the client as destructive. `open_world_hint` is false everywhere: every tool acts
  # on this one user's closed dataset.
  class Tool < MCP::Tool
    UNREACHABLE = "The library is unreachable right now. Try again in a moment."
    LIST_CAP = 100

    class << self
      def reads!
        annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      end

      def writes!(idempotent: false)
        annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: idempotent, open_world_hint: false)
      end

      def call(server_context:, **args)
        ok(perform(server_context[:user], **args))
      rescue NotFound, Refused, FileLayer::UnsupportedOperation => e
        refuse(e.message)
      rescue ActiveRecord::RecordNotFound
        refuse("Not found.")
      rescue ActiveRecord::RecordInvalid => e
        refuse("#{e.record.errors.full_messages.join(". ")}.")
      rescue FileLayer::NotFound => e
        refuse(e.message.presence || "Not found.")
      rescue FileLayer::FetchError
        refuse(UNREACHABLE)
      end

      def perform(_user, **)
        raise NotImplementedError, "#{name} must define self.perform(user, **args)"
      end

      # One text block of compact JSON for the model to read, and the same hash as structuredContent
      # for a client that parses.
      def ok(payload)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ], structured_content: payload)
      end

      def refuse(message)
        MCP::Tool::Response.new([ { type: "text", text: message } ], error: true)
      end

      # --- Finders. EVERY ONE STARTS FROM THE USER (§8): a foreign slug or id is NotFound here, and
      # a bare `Maker::Project.find` must never appear in a tool (isolation_test.rb).
      def project!(user, slug)
        user.maker_projects.find_by(slug: slug.to_s) || raise(NotFound, "No project #{slug.to_s.inspect}.")
      end

      def task!(user, id)
        user.maker_tasks.find_by(id: id) || raise(NotFound, "No task with id #{id}.")
      end

      def item!(user, id)
        user.maker_inventory_items.find_by(id: id) || raise(NotFound, "No inventory item with id #{id}.")
      end

      def bom_line!(user, id)
        user.maker_bom_lines.find_by(id: id) || raise(NotFound, "No BOM line with id #{id}.")
      end

      # The Files page's case-insensitive LIKE pattern (SearchController): the caller's clause must
      # carry `ESCAPE '\'`, which is what makes sanitize_sql_like do anything on SQLite.
      def like(model, q)
        "%#{model.sanitize_sql_like(q.to_s.downcase)}%"
      end

      # `cap + 1` rows, then the cap: one query answers both the page and whether it was cut.
      def capped(scope, cap = LIST_CAP)
        rows = scope.limit(cap + 1).to_a
        [ rows.first(cap), rows.size > cap ]
      end
    end
  end
end
```

- [ ] **Step 5: Render**

Create `app/services/mcp_server/render.rb`:

```ruby
# frozen_string_literal: true

module McpServer
  # THE ONE PLACE A ROW IS SHAPED FOR AN LLM (spec §3). Names and paths over bare ids where a name
  # exists, ISO-8601 UTC times, floats for the decimal columns, nothing a model has to join by hand.
  # Every method takes what it renders already LOADED -- `tree:` is the one Maker::LibraryTree the
  # tool built, `open_tasks:` a count the tool grouped, `project:` the project a task's caller
  # already holds -- so rendering N rows adds no query (test/integration/mcp/query_budget_test.rb).
  module Render
    module_function

    def time(t) = t&.utc&.iso8601
    def number(d) = d&.to_f

    # `nodes.mtime` is unix NANOSECONDS (FileLayer::FileInfo), never seconds.
    def mtime(nanos) = nanos && Time.at(Rational(nanos, 1_000_000_000)).utc.iso8601

    def project(p, tree:, open_tasks: nil)
      { slug: p.slug, name: p.name, status: p.status, kind: p.kind, visibility: p.visibility,
        folder: folder_path(p, tree), open_tasks: open_tasks, updated_at: time(p.updated_at) }.compact
    end

    # nil when the project has no folder yet, or its folder is in the trash (a broken chain):
    # Maker::Project#ensure_library_folder!'s "nil is part of the contract".
    def folder_path(p, tree) = p.folder_node_id.presence && tree.path_for(p.folder_node_id)

    # `project:` defaults to the task's own taskable, evaluated only when not given, so a caller
    # holding the project passes it and pays no query; ListTasks preloads taskable instead.
    def task(t, project: t.taskable)
      { id: t.id, title: t.title, status: t.status, notes: t.notes, position: t.position,
        project: (project.slug if project.is_a?(Maker::Project)),
        completed_at: time(t.completed_at), updated_at: time(t.updated_at) }
    end

    def entry(e)
      { id: e.id, entry_type: e.entry_type, logged_at: time(e.logged_at), body: e.body.to_plain_text }
    end

    def item(i, full: false)
      base = { id: i.id, name: i.name, part_number: i.part_number, category: i.category,
               quantity: number(i.quantity_cached), unit: i.unit, min_quantity: number(i.min_quantity),
               low_stock: i.low_stock?, location: i.location&.name, supplier: i.supplier&.name }
      return base unless full

      base.merge(unit_cost: number(i.unit_cost), notes: i.notes, location_id: i.location_id,
                 supplier_id: i.supplier_id, updated_at: time(i.updated_at))
    end

    def transaction(t)
      { id: t.id, delta: number(t.delta), reason: t.reason, note: t.note, project_id: t.project_id,
        at: time(t.created_at) }
    end

    def bom(b, lines: nil) = { id: b.id, name: b.name, revision: b.revision, lines: lines }.compact

    def line(l)
      item = (l.inventory_item if l.target_kind == :inventory_item)
      { id: l.id, reference: l.reference, quantity: number(l.quantity), unit: l.unit, kind: l.target_kind,
        item: item && { id: item.id, name: item.name, on_hand: number(item.quantity_cached) },
        part_name: l.part_name, node_id: l.node_id, supplier: l.supplier&.name, notes: l.notes }
    end

    def supplier(s) = { id: s.id, name: s.name, url: s.url, notes: s.notes }

    def location(l)
      { id: l.id, name: l.name, parent_id: l.parent_id, parent: l.parent&.name, description: l.description }
    end

    # `path:` is computed by the caller (LibraryPath), who knows the folder it listed.
    def node(n, path:)
      { name: n.name, kind: n.kind, path: path, node_id: n.node_id, size: n.size, modified_at: mtime(n.mtime),
        text: n.file? && Maker::FileAttachment.text?(n.name) }
    end
  end
end
```

- [ ] **Step 6: LibraryPath**

Create `app/services/mcp_server/library_path.rb`:

```ruby
# frozen_string_literal: true

module McpServer
  # LIBRARY-RELATIVE PATHS, BOTH WAYS (spec §5). A model names a file or folder as
  # "Projects/lamp/README.md"; this resolves that to the live node, one query per segment, and
  # writes the path of a node it lists back from the folder it was asked about.
  #
  # REJECTS, NEVER NORMALISES: `.` and `..` are refused outright rather than resolved (§14a's
  # `key_for` rule -- a normalised `a/../b` is a valid path to the wrong file). Depth is capped so a
  # pathological path costs at most MAX_SEGMENTS queries.
  #
  # ONLY THE CATALOG IS READ. `nodes` is populated on every backend (§5), so this answers the same on
  # share, s3 and chunk_remote, and nothing here touches the port or the changelog (§2).
  module LibraryPath
    MAX_SEGMENTS = 32

    module_function

    def segments(path)
      segs = path.to_s.split("/").reject(&:empty?)
      if segs.any? { |s| s == "." || s == ".." }
        raise Refused, "A path is library-relative, like \"Projects/lamp/README.md\": no \".\" or \"..\" segments."
      end
      raise Refused, "That path is deeper than #{MAX_SEGMENTS} folders." if segs.size > MAX_SEGMENTS

      segs
    end

    # The live node at `path`; nil for the library root (a blank path or "/"). Raises NotFound for
    # anything that does not resolve, naming the path as given.
    def resolve!(user, path)
      node = nil
      segments(path).each do |name|
        node = user.nodes.present.find_by(parent_node_id: node&.node_id, name: name)
        raise NotFound, "No file or folder at #{path.to_s.inspect}." if node.nil?
      end
      node
    end

    # The normalised spelling of a path the model gave ("" for the root), so listings join on it.
    def normalize(path) = segments(path).join("/")

    def join(base, name) = base.empty? ? name : "#{base}/#{name}"

    # A node's path from the tree the caller built; nil when an ancestor is tombstoned or missing
    # (Maker::LibraryTree#path_for's "nil is an answer"), rendered as `path: null`, never guessed.
    def of(tree, node)
      parent = tree.path_for(node.parent_node_id)
      parent && join(parent, node.name)
    end
  end
end
```

- [ ] **Step 7: The seven module stubs**

Create each of these files with exactly this body (module name per file):

`app/services/mcp_server/tools/projects.rb`:
```ruby
# frozen_string_literal: true

module McpServer
  module Tools
    module Projects
      def self.all = []
    end
  end
end
```
`tasks.rb` → `module Tasks`; `build_log.rb` → `module BuildLog`; `inventory.rb` → `module Inventory`; `bom.rb` → `module Bom`; `reference.rb` → `module Reference`; `library.rb` → `module Library`. Same `def self.all = []` in each.

- [ ] **Step 8: The controller**

Create `app/controllers/mcp_controller.rb`:

```ruby
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
```

- [ ] **Step 9: The route**

In `config/routes.rb`, immediately before the line `  namespace :v1 do`, insert:

```ruby
  # THE MCP DOOR (2026-11-04, spec 2026-11-04-mcp-server-design). POST carries one JSON-RPC
  # message; GET and DELETE answer the transport spec's shapes for a server with no session
  # (McpController). Device-token authed like /v1, never the web session.
  post   "mcp", to: "mcp#create"
  get    "mcp", to: "mcp#show"
  delete "mcp", to: "mcp#destroy"
```

Run: `bin/rails routes -g mcp`
Expected: three lines, `mcp#create`, `mcp#show`, `mcp#destroy`.

- [ ] **Step 10: The test client**

Create `test/support/mcp_client.rb`:

```ruby
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
```

- [ ] **Step 11: The protocol test**

Create `test/integration/mcp/protocol_test.rb`:

```ruby
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
```

- [ ] **Step 12: Run it**

Run (with your env from the dispatch rules): `bin/rails test test/integration/mcp/protocol_test.rb`
Expected: 9 runs, 0 failures, 0 errors.

- [ ] **Step 13: Mutation checks (report the actual output of each)**

1. In `mcp_controller.rb` change `include V1::Authentication` to a comment → the 401 test goes red (three requests answer 200/202). Restore.
2. In `mcp_controller.rb` change `MAX_BODY + 1` to `MAX_BODY` and `> MAX_BODY` to `> MAX_BODY + 1` → the 413 test goes red. Restore.
3. In `mcp_controller.rb#show` delete the `Allow` header line → the 405 test goes red. Restore.

- [ ] **Step 14: Style and the two guards that reach a new controller**

Run: `bin/rubocop app/controllers/mcp_controller.rb app/services/mcp_server.rb app/services/mcp_server config/initializers/mcp.rb test/support/mcp_client.rb test/integration/mcp`
Expected: no offenses.

Run: `bin/rails test test/architecture_invariants_test.rb test/ci_hygiene_test.rb`
Expected: green (the new controller rescues nothing; no importmap pin changed).

Report: file list, test output, the three mutation outputs.

---

### Task 2: Projects tools

**Files:**
- Modify: `app/services/mcp_server/tools/projects.rb` (replace the stub)
- Create: `test/integration/mcp/projects_tools_test.rb`

- [ ] **Step 1: Write the test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  class ProjectsToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      # create_project mints Projects/<slug> THROUGH THE PORT -- a real mkdir. On a root this test
      # owns it is the same on every backend leg; on the ambient adapter it is Forbidden on s3 and
      # a provisioning call on chunk_remote (project-folder fixtures must be port-free otherwise).
      @root = use_fresh_share_library!
      @token = bootstrap_token(email: "mcp-projects@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-projects@example.com")
    end

    test "create_project derives the slug, makes the folder and answers its path" do
      out = mcp_structured(@token, "create_project", { name: "Desk Lamp", kind: "laser", description: "A lamp" })
      assert_equal "desk-lamp", out["slug"]
      assert_equal "Projects/desk-lamp", out["folder"]
      assert_equal "laser", out["kind"]
      assert_equal "A lamp", out["description"]
      assert_nil out["note"]
      project = @user.maker_projects.find_by!(slug: "desk-lamp")
      assert @user.nodes.present.find_by(node_id: project.folder_node_id, kind: "dir")
    end

    test "create_project still creates the project when the library is unreachable, and says so" do
      replacing(FileLayer.current, :mkdir, ->(*, **) { raise FileLayer::FetchError, "mount gone" }) do
        out = mcp_structured(@token, "create_project", { name: "Offline" })
        assert_equal "offline", out["slug"]
        assert_nil out["folder"]
        assert_match(/could not be reached/, out["note"])
      end
      assert @user.maker_projects.find_by(slug: "offline")
    end

    test "create_project refuses a blank name as a validation message, not a crash" do
      message = mcp_refusal(@token, "create_project", { name: "   " })
      assert_match(/Name can't be blank/, message)
    end

    test "list_projects lists newest change first with folder path and open task count, and filters" do
      lamp = @user.maker_projects.create!(name: "Lamp", status: "active")
      project_folder_rows!(@user, lamp)
      @user.maker_tasks.create!(taskable: lamp, title: "Cut base")
      @user.maker_tasks.create!(taskable: lamp, title: "Done one", status: "done")
      @user.maker_projects.create!(name: "Old box", status: "done")

      out = mcp_structured(@token, "list_projects")
      assert_equal %w[old-box lamp], out["projects"].map { |p| p["slug"] }
      row = out["projects"].find { |p| p["slug"] == "lamp" }
      assert_equal "Projects/lamp", row["folder"]
      assert_equal 1, row["open_tasks"]
      assert_equal false, out["truncated"]

      assert_equal [ "lamp" ], mcp_structured(@token, "list_projects", { status: "active" })["projects"].map { |p| p["slug"] }
      assert_equal [ "old-box" ], mcp_structured(@token, "list_projects", { q: "BOX" })["projects"].map { |p| p["slug"] }
    end

    test "list_projects is capped and says so" do
      (McpServer::Tool::LIST_CAP + 1).times { |i| @user.maker_projects.create!(name: "P#{i}") }
      out = mcp_structured(@token, "list_projects")
      assert_equal McpServer::Tool::LIST_CAP, out["projects"].size
      assert_equal true, out["truncated"]
    end

    test "get_project answers tasks open first, the build log newest first, BOMs and attached files" do
      lamp = @user.maker_projects.create!(name: "Lamp", description: "RGB")
      folder = project_folder_rows!(@user, lamp)
      done = @user.maker_tasks.create!(taskable: lamp, title: "Done", status: "done", position: 0)
      open = @user.maker_tasks.create!(taskable: lamp, title: "Open", status: "todo", position: 1)
      lamp.build_log_entries.create!(user: @user, body: "first", logged_at: 2.days.ago)
      lamp.build_log_entries.create!(user: @user, body: "second", logged_at: 1.day.ago)
      bom = lamp.boms.create!(user: @user)
      bom.lines.create!(user: @user, part_name: "M3 bolt", quantity: 4)
      file = @user.nodes.create!(node_id: SecureRandom.uuid, name: "lid.stl", kind: "file",
                                 parent_node_id: folder.node_id, mtime: 1, size: 10)
      lamp.file_attachments.create!(user: @user, node_id: file.node_id, role: "model", label: "Lid")

      out = mcp_structured(@token, "get_project", { slug: "lamp" })
      assert_equal "RGB", out["description"]
      assert_equal [ open.id, done.id ], out["tasks"].map { |t| t["id"] }
      assert_equal %w[second first], out["build_log"].map { |e| e["body"] }
      assert_equal [ { "id" => bom.id, "name" => "BOM", "revision" => 1, "lines" => 1 } ], out["boms"]
      assert_equal [ "Projects/lamp/lid.stl" ], out["files"].map { |f| f["path"] }
      assert_equal "Lid", out["files"].first["label"]
    end

    test "get_project names a missing slug" do
      assert_equal "No project \"nope\".", mcp_refusal(@token, "get_project", { slug: "nope" })
    end

    test "update_project changes only the given fields, archives and unarchives" do
      lamp = @user.maker_projects.create!(name: "Lamp", description: "keep", status: "active")
      out = mcp_structured(@token, "update_project", { slug: "lamp", name: "Desk lamp" })
      assert_equal "Desk lamp", out["name"]
      assert_equal "keep", lamp.reload.description

      out = mcp_structured(@token, "update_project", { slug: "lamp", status: "archived" })
      assert_equal "archived", out["status"]
      assert lamp.reload.archived_at.present?
      assert_equal lamp.archived_at.utc.iso8601, out["archived_at"]

      mcp_structured(@token, "update_project", { slug: "lamp", status: "active" })
      assert_nil lamp.reload.archived_at
    end

    test "a misspelt argument is refused by the schema, never a crash" do
      message = mcp_refusal(@token, "get_project", { slugg: "lamp" })
      assert_match(/slugg|additional property|Missing required/, message)
    end
  end
end
```

- [ ] **Step 2: Run it, expect red** (`NotImplementedError`/unknown tool: `tools/call` of an unknown name is a JSON-RPC -32602, which `mcp_tool` flunks).

- [ ] **Step 3: Write the module**

Replace `app/services/mcp_server/tools/projects.rb`:

```ruby
# frozen_string_literal: true

module McpServer
  module Tools
    # PROJECTS: list, read, create, update. Never delete (spec §4): archiving is a status.
    module Projects
      def self.all = [ ListProjects, GetProject, CreateProject, UpdateProject ]

      class ListProjects < McpServer::Tool
        tool_name "list_projects"
        description "List this user's projects, newest change first: slug, name, status, kind, " \
                    "library folder path, open task count. Filter by status " \
                    "(#{Maker::Project::STATUSES.join(", ")}) and/or a name substring. " \
                    "At most #{LIST_CAP} rows; truncated is true when there were more."
        input_schema(
          properties: {
            status: { type: "string", enum: Maker::Project::STATUSES },
            q: { type: "string", maxLength: 80, description: "A substring of the name, case-insensitive." }
          },
          required: [], additionalProperties: false
        )
        reads!

        def self.perform(user, status: nil, q: nil)
          scope = user.maker_projects.by_status(status).order(updated_at: :desc, id: :desc)
          scope = scope.where("LOWER(name) LIKE ? ESCAPE '\\'", like(Maker::Project, q)) if q.present?
          rows, truncated = capped(scope)
          tree = Maker::LibraryTree.new(user)
          open = user.maker_tasks.open.where(taskable_type: "Maker::Project", taskable_id: rows.map(&:id))
                     .group(:taskable_id).count
          { projects: rows.map { |p| Render.project(p, tree:, open_tasks: open.fetch(p.id, 0)) }, truncated: }
        end
      end

      class GetProject < McpServer::Tool
        ENTRIES = 20

        tool_name "get_project"
        description "One project in full: description, status, kind, visibility, folder path, its " \
                    "tasks (open first), the last #{ENTRIES} build-log entries newest first, its BOMs " \
                    "with line counts, and the files attached to it with their paths."
        input_schema(properties: { slug: { type: "string" } }, required: %w[slug], additionalProperties: false)
        reads!

        def self.perform(user, slug:)
          p = project!(user, slug)
          tree = Maker::LibraryTree.new(user)
          tasks = p.tasks.reorder(Arel.sql("CASE status WHEN 'done' THEN 1 ELSE 0 END"), :position, :id).to_a
          entries = p.build_log_entries.reorder(logged_at: :desc, id: :desc).limit(ENTRIES)
                     .includes(:rich_text_body).to_a
          boms = p.boms.order(:id).to_a
          counts = Maker::BomLine.where(bom_id: boms.map(&:id)).group(:bom_id).count
          attachments = p.file_attachments.to_a
          nodes = user.nodes.present.where(node_id: attachments.map(&:node_id)).index_by(&:node_id)
          Render.project(p, tree:, open_tasks: tasks.count { |t| t.status != "done" }).merge(
            description: p.description,
            archived_at: Render.time(p.archived_at),
            tasks: tasks.map { |t| Render.task(t, project: p) },
            build_log: entries.map { |e| Render.entry(e) },
            boms: boms.map { |b| Render.bom(b, lines: counts.fetch(b.id, 0)) },
            files: attachments.filter_map do |a|
              node = nodes[a.node_id] or next
              { path: LibraryPath.of(tree, node), name: node.name, role: a.role, label: a.label, node_id: node.node_id }
            end
          )
        end
      end

      class CreateProject < McpServer::Tool
        tool_name "create_project"
        description "Create a project. The slug is derived from the name. Its library folder " \
                    "Projects/<slug> is made too; if the library cannot be reached the project still " \
                    "exists and the answer carries a note."
        input_schema(
          properties: {
            name: { type: "string", minLength: 1, maxLength: 200 },
            description: { type: "string" },
            status: { type: "string", enum: Maker::Project::STATUSES },
            kind: { type: "string", enum: Maker::Project::KINDS }
          },
          required: %w[name], additionalProperties: false
        )
        writes!

        def self.perform(user, name:, description: nil, status: nil, kind: nil)
          p = user.maker_projects.create!({ name:, description:, status:, kind: }.compact)
          note = ensure_folder(user, p)
          Render.project(p, tree: Maker::LibraryTree.new(user), open_tasks: 0)
                .merge(description: p.description, note: note).compact
        end

        # ProjectsController#ensure_project_folder's best effort, for its reason: the project exists
        # whether or not the library answered, and the folder is tried again on the next project
        # view. Only the two port failures are swallowed; anything else propagates.
        def self.ensure_folder(user, p)
          p.ensure_library_folder!(user)
          nil
        rescue FileLayer::FetchError
          "The library could not be reached, so the project folder was not created yet. It is made " \
            "the next time the project is opened while the library is available."
        rescue FileLayer::UnsupportedOperation
          "The project folder could not be made in the library; a file or folder there may already " \
            "have its name. It is tried again each time the project is opened."
        end
      end

      class UpdateProject < McpServer::Tool
        tool_name "update_project"
        description "Change a project's name, description, status or kind; only the fields given " \
                    "change. A status of \"archived\" archives it (stamping archived_at); any other " \
                    "status unarchives it. There is no delete."
        input_schema(
          properties: {
            slug: { type: "string" },
            name: { type: "string", minLength: 1, maxLength: 200 },
            description: { type: "string" },
            status: { type: "string", enum: Maker::Project::STATUSES },
            kind: { type: "string", enum: Maker::Project::KINDS }
          },
          required: %w[slug], additionalProperties: false
        )
        writes!(idempotent: true)

        def self.perform(user, slug:, name: nil, description: nil, status: nil, kind: nil)
          p = project!(user, slug)
          p.assign_attributes({ name:, description:, kind:, status: }.compact)
          # Maker::Project#archive! / #unarchive! in one save: the stamp follows the status.
          p.archived_at = (status == "archived" ? (p.archived_at || Time.current) : nil) if status
          p.save!
          Render.project(p, tree: Maker::LibraryTree.new(user))
                .merge(description: p.description, archived_at: Render.time(p.archived_at))
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it, expect green** (`bin/rails test test/integration/mcp/projects_tools_test.rb` → 9 runs, 0 failures).

- [ ] **Step 5: Mutation checks (report actual output)**

1. In `GetProject.perform` change `project!(user, slug)` to `Maker::Project.find_by!(slug: slug)` → "get_project names a missing slug" goes red (a `RecordNotFound` is "Not found.", not the named sentence). Restore.
2. In `ListProjects.perform` change `open.fetch(p.id, 0)` to `0` → the open_tasks assertion goes red. Restore.
3. In `CreateProject.perform` swap `ensure_folder` for `nil` → the folder assertion goes red. Restore.

- [ ] **Step 6: `bin/rubocop app/services/mcp_server/tools/projects.rb test/integration/mcp/projects_tools_test.rb`** → no offenses. Report.

---

### Task 3: Tasks and build-log tools

**Files:**
- Modify: `app/services/mcp_server/tools/tasks.rb`, `app/services/mcp_server/tools/build_log.rb` (replace stubs)
- Create: `test/integration/mcp/tasks_tools_test.rb`

- [ ] **Step 1: Write the test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  class TasksToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @token = bootstrap_token(email: "mcp-tasks@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-tasks@example.com")
      @lamp = @user.maker_projects.create!(name: "Lamp")
      @box = @user.maker_projects.create!(name: "Box")
    end

    test "list_tasks answers every project's tasks open first, or one project's, or one status" do
      done = @user.maker_tasks.create!(taskable: @lamp, title: "Done", status: "done", position: 0)
      open = @user.maker_tasks.create!(taskable: @lamp, title: "Open", position: 1)
      boxed = @user.maker_tasks.create!(taskable: @box, title: "Boxed", position: 2)

      out = mcp_structured(@token, "list_tasks")
      # Open first (the CASE), then position: open (1) before boxed (2), done last whatever its position.
      assert_equal [ open.id, boxed.id, done.id ], out["tasks"].map { |t| t["id"] }
      assert_equal %w[lamp box lamp], out["tasks"].map { |t| t["project"] }

      assert_equal [ open.id, done.id ], mcp_structured(@token, "list_tasks", { project: "lamp" })["tasks"].map { |t| t["id"] }
      assert_equal [ done.id ], mcp_structured(@token, "list_tasks", { status: "done" })["tasks"].map { |t| t["id"] }
      assert_equal "No project \"nope\".", mcp_refusal(@token, "list_tasks", { project: "nope" })
    end

    test "create_task attaches to the project and a done status stamps completed_at" do
      out = mcp_structured(@token, "create_task", { project: "lamp", title: "Cut base", notes: "3 mm ply" })
      task = @user.maker_tasks.find(out.dig("task", "id"))
      assert_equal @lamp, task.taskable
      assert_equal "todo", task.status
      assert_nil task.completed_at
      assert_equal "lamp", out.dig("task", "project")

      out = mcp_structured(@token, "create_task", { project: "lamp", title: "Already done", status: "done" })
      assert @user.maker_tasks.find(out.dig("task", "id")).completed_at.present?
    end

    test "update_task changes the given fields and follows the v1 completed_at rule" do
      task = @user.maker_tasks.create!(taskable: @lamp, title: "Cut")
      out = mcp_structured(@token, "update_task", { id: task.id, status: "done" })
      assert_equal "done", out.dig("task", "status")
      stamp = task.reload.completed_at
      assert stamp.present?

      mcp_structured(@token, "update_task", { id: task.id, title: "Cut base" })
      assert_equal stamp, task.reload.completed_at, "a title change keeps the stamp"

      mcp_structured(@token, "update_task", { id: task.id, status: "doing" })
      assert_nil task.reload.completed_at
      assert_equal "No task with id 0.", mcp_refusal(@token, "update_task", { id: 0, title: "x" })
    end

    test "list_build_log answers newest first, as plain text, limited" do
      3.times { |i| @lamp.build_log_entries.create!(user: @user, body: "entry #{i}", logged_at: i.days.ago) }
      out = mcp_structured(@token, "list_build_log", { project: "lamp", limit: 2 })
      assert_equal [ "entry 0", "entry 1" ], out["entries"].map { |e| e["body"] }
      assert_equal "lamp", out["project"]
    end

    test "add_build_log_entry keeps plain text plain, makes paragraphs, and takes a time" do
      out = mcp_structured(@token, "add_build_log_entry",
                           { project: "lamp", body: "Glued the base.\n\nLeft it <overnight>.",
                             entry_type: "milestone", logged_at: "2026-11-01T10:00:00Z" })
      entry = @lamp.build_log_entries.find(out.dig("entry", "id"))
      assert_equal "milestone", entry.entry_type
      assert_equal Time.utc(2026, 11, 1, 10), entry.logged_at
      assert_includes entry.body.to_s, "<p>Glued the base.</p>"
      assert_includes entry.body.to_s, "&lt;overnight&gt;"
      assert_equal "Glued the base.\n\nLeft it <overnight>.", out.dig("entry", "body")
    end

    test "add_build_log_entry refuses a time it cannot read, and defaults to now" do
      assert_match(/ISO-8601/, mcp_refusal(@token, "add_build_log_entry", { project: "lamp", body: "x", logged_at: "yesterday-ish" }))
      out = mcp_structured(@token, "add_build_log_entry", { project: "lamp", body: "now" })
      assert_in_delta Time.current, @lamp.build_log_entries.find(out.dig("entry", "id")).logged_at, 5
    end
  end
end
```

- [ ] **Step 2: Run it, expect red.**

- [ ] **Step 3: Write both modules**

`app/services/mcp_server/tools/tasks.rb`:

```ruby
# frozen_string_literal: true

module McpServer
  module Tools
    # TASKS: across every project or one, open first. A task's owner here is always a project
    # (Maker::Task's other taskable, an Item, is the catalog layer the MCP leaves out; spec §4).
    module Tasks
      def self.all = [ ListTasks, CreateTask, UpdateTask ]

      # Open first, then the maker's own order.
      ORDER = [ Arel.sql("CASE status WHEN 'done' THEN 1 ELSE 0 END"), :position, :id ].freeze

      class ListTasks < McpServer::Tool
        tool_name "list_tasks"
        description "Tasks across every project, or one project's (give its slug), open tasks first. " \
                    "Filter by status (#{Maker::Task::STATUSES.join(", ")}). At most #{LIST_CAP}."
        input_schema(
          properties: {
            project: { type: "string", description: "A project slug." },
            status: { type: "string", enum: Maker::Task::STATUSES }
          },
          required: [], additionalProperties: false
        )
        reads!

        def self.perform(user, project: nil, status: nil)
          scope = user.maker_tasks.includes(:taskable).order(*ORDER)
          scope = scope.where(taskable: project!(user, project)) if project
          scope = scope.where(status: status) if status
          rows, truncated = capped(scope)
          { tasks: rows.map { |t| Render.task(t) }, truncated: }
        end
      end

      class CreateTask < McpServer::Tool
        tool_name "create_task"
        description "Add a task to a project. status defaults to todo; done stamps completed_at."
        input_schema(
          properties: {
            project: { type: "string", description: "The project's slug." },
            title: { type: "string", minLength: 1, maxLength: 200 },
            notes: { type: "string" },
            status: { type: "string", enum: Maker::Task::STATUSES }
          },
          required: %w[project title], additionalProperties: false
        )
        writes!

        def self.perform(user, project:, title:, notes: nil, status: nil)
          p = project!(user, project)
          t = user.maker_tasks.create!(taskable: p, title: title, notes: notes, status: status || "todo",
                                       completed_at: (Time.current if status == "done"))
          { task: Render.task(t, project: p) }
        end
      end

      class UpdateTask < McpServer::Tool
        tool_name "update_task"
        description "Change a task's title, notes or status; only the fields given change. " \
                    "done stamps completed_at once; any other status clears it."
        input_schema(
          properties: {
            id: { type: "integer" },
            title: { type: "string", minLength: 1, maxLength: 200 },
            notes: { type: "string" },
            status: { type: "string", enum: Maker::Task::STATUSES }
          },
          required: %w[id], additionalProperties: false
        )
        writes!(idempotent: true)

        def self.perform(user, id:, title: nil, notes: nil, status: nil)
          t = task!(user, id)
          attrs = { title:, notes:, status: }.compact
          # V1::Maker::TasksController#update's rule, kept identical so the two doors agree.
          if status == "done"
            attrs[:completed_at] = t.completed_at || Time.current
          elsif status
            attrs[:completed_at] = nil
          end
          t.update!(attrs)
          { task: Render.task(t) }
        end
      end
    end
  end
end
```

`app/services/mcp_server/tools/build_log.rb`:

```ruby
# frozen_string_literal: true

module McpServer
  module Tools
    # THE BUILD LOG: read newest first, add a note or a milestone. The body crosses this wire as
    # PLAIN TEXT in both directions, as it does on v1 (BuildLogEntriesController#entry_json).
    module BuildLog
      def self.all = [ ListBuildLog, AddBuildLogEntry ]

      class ListBuildLog < McpServer::Tool
        DEFAULT = 20
        MAX = 100

        tool_name "list_build_log"
        description "A project's build-log entries, newest first, as plain text. limit defaults to " \
                    "#{DEFAULT} and may be up to #{MAX}."
        input_schema(
          properties: {
            project: { type: "string", description: "The project's slug." },
            limit: { type: "integer", minimum: 1, maximum: MAX }
          },
          required: %w[project], additionalProperties: false
        )
        reads!

        def self.perform(user, project:, limit: DEFAULT)
          p = project!(user, project)
          rows = p.build_log_entries.reorder(logged_at: :desc, id: :desc).limit(limit).includes(:rich_text_body).to_a
          { project: p.slug, entries: rows.map { |e| Render.entry(e) } }
        end
      end

      class AddBuildLogEntry < McpServer::Tool
        tool_name "add_build_log_entry"
        description "Add a note or a milestone to a project's build log. body is plain text; a blank " \
                    "line separates paragraphs. logged_at is ISO-8601 and defaults to now."
        input_schema(
          properties: {
            project: { type: "string", description: "The project's slug." },
            body: { type: "string", minLength: 1 },
            entry_type: { type: "string", enum: Maker::BuildLogEntry::ENTRY_TYPES },
            logged_at: { type: "string", description: "ISO-8601, e.g. 2026-11-04T10:00:00Z." }
          },
          required: %w[project body], additionalProperties: false
        )
        writes!

        def self.perform(user, project:, body:, entry_type: "note", logged_at: nil)
          p = project!(user, project)
          e = p.build_log_entries.create!(user: user, entry_type: entry_type, logged_at: parse_time!(logged_at),
                                          body: html_from_plain(body))
          { entry: Render.entry(e) }
        end

        # nil is "now"; anything Time.zone cannot read is refused in words. The rescue is the one
        # named case (Time.zone.parse raises ArgumentError on an out-of-range field) and never a
        # bare rescue_from.
        def self.parse_time!(value)
          return Time.current if value.nil?

          Time.zone.parse(value.to_s) || raise(Refused, "logged_at must be an ISO-8601 time, like 2026-11-04T10:00:00Z.")
        rescue ArgumentError
          raise Refused, "logged_at must be an ISO-8601 time, like 2026-11-04T10:00:00Z."
        end

        # Plain text in, the editor's paragraphs out: the text is ESCAPED first, so a "<" in a note
        # stays a "<", then each blank-line-separated block becomes a <p> and a single newline a
        # <br>. Maker::TextOnlyRichText then runs as on every door.
        def self.html_from_plain(text)
          ActionController::Base.helpers.simple_format(ERB::Util.html_escape(text.to_s), {}, sanitize: false)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it, expect green** (6 runs).

- [ ] **Step 5: Mutation checks (report actual output)**

1. In `UpdateTask.perform` delete the `elsif status` arm → "follows the v1 completed_at rule" goes red. Restore.
2. In `AddBuildLogEntry.html_from_plain` drop `ERB::Util.html_escape(` … `)` → the `&lt;overnight&gt;` assertion goes red. Restore.
3. In `ListTasks.perform` change `.order(*ORDER)` to `.order(:id)` → the open-first assertion goes red. Restore.

- [ ] **Step 6: `bin/rubocop` on the three files** → no offenses. Report.

---

### Task 4: Inventory tools

**Files:**
- Modify: `app/services/mcp_server/tools/inventory.rb` (replace the stub)
- Create: `test/integration/mcp/inventory_tools_test.rb`

- [ ] **Step 1: Write the test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  class InventoryToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @token = bootstrap_token(email: "mcp-inventory@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-inventory@example.com")
      @bench = @user.maker_locations.create!(name: "Bench")
      @shop = @user.maker_suppliers.create!(name: "Shop")
    end

    def item!(name, qty: 0, **attrs)
      item = @user.maker_inventory_items.create!({ name: name }.merge(attrs))
      Maker::InventoryTransaction.apply!(item: item, user: @user, delta: qty, reason: "initial") if qty != 0
      item.reload
    end

    test "list_inventory answers by name with location, supplier and low_stock, and filters" do
      bolts = item!("M3 bolt", qty: 100, part_number: "B-M3", location: @bench, supplier: @shop, min_quantity: 10)
      ply = item!("Ply 3mm", qty: 2, min_quantity: 5, unit: "sheet")

      out = mcp_structured(@token, "list_inventory")
      assert_equal [ bolts.id, ply.id ], out["items"].map { |i| i["id"] }
      row = out["items"].first
      assert_equal({ "quantity" => 100.0, "unit" => "each", "location" => "Bench", "supplier" => "Shop", "low_stock" => false },
                   row.slice("quantity", "unit", "location", "supplier", "low_stock"))
      assert_equal true, out["items"].last["low_stock"]

      assert_equal [ ply.id ], mcp_structured(@token, "list_inventory", { low_stock: true })["items"].map { |i| i["id"] }
      assert_equal [ bolts.id ], mcp_structured(@token, "list_inventory", { location_id: @bench.id })["items"].map { |i| i["id"] }
      assert_equal [ bolts.id ], mcp_structured(@token, "list_inventory", { q: "b-m3" })["items"].map { |i| i["id"] }
    end

    test "get_inventory_item answers the full row and its ledger newest first" do
      bolts = item!("M3 bolt", qty: 100, unit_cost: 0.05, notes: "zinc")
      Maker::InventoryTransaction.apply!(item: bolts, user: @user, delta: -4, reason: "consumed")
      out = mcp_structured(@token, "get_inventory_item", { id: bolts.id })
      assert_equal 96.0, out.dig("item", "quantity")
      assert_equal 0.05, out.dig("item", "unit_cost")
      assert_equal "zinc", out.dig("item", "notes")
      assert_equal [ -4.0, 100.0 ], out["transactions"].map { |t| t["delta"] }
      assert_equal "No inventory item with id 0.", mcp_refusal(@token, "get_inventory_item", { id: 0 })
    end

    test "create_inventory_item posts the opening quantity to the ledger as initial stock" do
      out = mcp_structured(@token, "create_inventory_item",
                           { name: "Nuts", quantity: 50, unit: "pack", min_quantity: 5, location_id: @bench.id })
      item = @user.maker_inventory_items.find(out.dig("item", "id"))
      assert_equal 50, item.quantity_cached
      assert_equal [ [ "initial", 50 ] ], item.transactions.map { |t| [ t.reason, t.delta.to_i ] }
      assert_equal "Bench", out.dig("item", "location")

      out = mcp_structured(@token, "create_inventory_item", { name: "Empty" })
      assert_empty @user.maker_inventory_items.find(out.dig("item", "id")).transactions
    end

    test "create_inventory_item refuses a foreign location in the model's words" do
      other = User.create!(email: "other-inv@example.com", confirmed_at: Time.current, omniauth_signup: true)
      theirs = other.maker_locations.create!(name: "Theirs")
      message = mcp_refusal(@token, "create_inventory_item", { name: "X", location_id: theirs.id })
      assert_match(/Location/i, message)
      assert_nil @user.maker_inventory_items.find_by(name: "X")
    end

    test "update_inventory_item changes the given fields and never the balance" do
      bolts = item!("M3 bolt", qty: 100)
      out = mcp_structured(@token, "update_inventory_item", { id: bolts.id, name: "M3 x 10 bolt", min_quantity: 20, supplier_id: @shop.id })
      assert_equal "M3 x 10 bolt", bolts.reload.name
      assert_equal 20, bolts.min_quantity
      assert_equal @shop, bolts.supplier
      assert_equal 100.0, out.dig("item", "quantity")
    end

    test "adjust_inventory posts a signed ledger row naming the project" do
      bolts = item!("M3 bolt", qty: 100)
      lamp = @user.maker_projects.create!(name: "Lamp")
      out = mcp_structured(@token, "adjust_inventory", { id: bolts.id, delta: -4, reason: "consumed", project: "lamp", note: "base" })
      assert_equal 96.0, out.dig("item", "quantity")
      txn = bolts.transactions.last
      assert_equal [ -4, "consumed", lamp.id, "base" ], [ txn.delta.to_i, txn.reason, txn.project_id, txn.note ]
      assert_equal txn.id, out.dig("transaction", "id")
      assert_equal "delta must not be zero.", mcp_refusal(@token, "adjust_inventory", { id: bolts.id, delta: 0 })
      assert_equal "No project \"nope\".", mcp_refusal(@token, "adjust_inventory", { id: bolts.id, delta: 1, project: "nope" })
    end
  end
end
```

- [ ] **Step 2: Run it, expect red.**

- [ ] **Step 3: Write the module**

```ruby
# frozen_string_literal: true

module McpServer
  module Tools
    # INVENTORY: the items, their ledger, and the one way the balance moves --
    # Maker::InventoryTransaction.apply!, exactly as v1's adjust and the web's composer post it.
    module Inventory
      def self.all = [ ListInventory, GetInventoryItem, CreateInventoryItem, UpdateInventoryItem, AdjustInventory ]

      CAP = 200

      # The editable columns, shared by create and update. `quantity` is NOT one: the balance is
      # the ledger's sum and only a transaction moves it.
      FIELDS = {
        part_number: { type: "string", maxLength: 100 },
        category: { type: "string", maxLength: 100 },
        unit: { type: "string", enum: Maker::InventoryItem::UNITS },
        min_quantity: { type: "number", minimum: 0 },
        unit_cost: { type: "number", minimum: 0 },
        location_id: { type: "integer" },
        supplier_id: { type: "integer" },
        notes: { type: "string" }
      }.freeze

      class ListInventory < McpServer::Tool
        tool_name "list_inventory"
        description "Inventory items by name: id, quantity on hand, unit, minimum, location, supplier, " \
                    "low_stock. Filter by a name or part-number substring, low_stock: true, or a " \
                    "location_id. At most #{CAP}."
        input_schema(
          properties: {
            q: { type: "string", maxLength: 80 },
            low_stock: { type: "boolean" },
            location_id: { type: "integer" }
          },
          required: [], additionalProperties: false
        )
        reads!

        def self.perform(user, q: nil, low_stock: nil, location_id: nil)
          scope = user.maker_inventory_items.includes(:location, :supplier).order(:name, :id)
          scope = scope.low_stock if low_stock
          scope = scope.where(location_id: location_id) if location_id
          if q.present?
            pattern = like(Maker::InventoryItem, q)
            scope = scope.where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(COALESCE(part_number, '')) LIKE ? ESCAPE '\\'",
                                pattern, pattern)
          end
          rows, truncated = capped(scope, CAP)
          { items: rows.map { |i| Render.item(i) }, truncated: }
        end
      end

      class GetInventoryItem < McpServer::Tool
        TRANSACTIONS = 20

        tool_name "get_inventory_item"
        description "One inventory item in full, with its last #{TRANSACTIONS} ledger transactions newest first."
        input_schema(properties: { id: { type: "integer" } }, required: %w[id], additionalProperties: false)
        reads!

        def self.perform(user, id:)
          i = item!(user, id)
          ledger = i.transactions.reorder(created_at: :desc, id: :desc).limit(TRANSACTIONS).to_a
          { item: Render.item(i, full: true), transactions: ledger.map { |t| Render.transaction(t) } }
        end
      end

      class CreateInventoryItem < McpServer::Tool
        tool_name "create_inventory_item"
        description "Add an inventory item. quantity is the opening stock, posted to the ledger as " \
                    "initial stock. unit is one of #{Maker::InventoryItem::UNITS.join(", ")} (default each)."
        input_schema(
          properties: { name: { type: "string", minLength: 1, maxLength: 200 }, quantity: { type: "number" } }.merge(FIELDS),
          required: %w[name], additionalProperties: false
        )
        writes!

        def self.perform(user, name:, quantity: nil, **fields)
          i = user.maker_inventory_items.create!({ name: name }.merge(fields))
          if quantity && !quantity.zero?
            Maker::InventoryTransaction.apply!(item: i, user: user, delta: quantity, reason: "initial")
            i.reload
          end
          { item: Render.item(i, full: true) }
        end
      end

      class UpdateInventoryItem < McpServer::Tool
        tool_name "update_inventory_item"
        description "Change an inventory item's name, part number, category, unit, minimum, unit cost, " \
                    "location, supplier or notes. Never the balance: use adjust_inventory."
        input_schema(
          properties: { id: { type: "integer" }, name: { type: "string", minLength: 1, maxLength: 200 } }.merge(FIELDS),
          required: %w[id], additionalProperties: false
        )
        writes!(idempotent: true)

        def self.perform(user, id:, **fields)
          i = item!(user, id)
          i.update!(fields)
          { item: Render.item(i, full: true) }
        end
      end

      class AdjustInventory < McpServer::Tool
        tool_name "adjust_inventory"
        description "Move an item's balance by a signed delta (negative takes stock out), posting a " \
                    "ledger row. reason is one of #{Maker::InventoryTransaction::REASONS.join(", ")} " \
                    "(default adjusted); project is a slug the row is attributed to."
        input_schema(
          properties: {
            id: { type: "integer" },
            delta: { type: "number" },
            reason: { type: "string", enum: Maker::InventoryTransaction::REASONS },
            note: { type: "string" },
            project: { type: "string", description: "A project slug." }
          },
          required: %w[id delta], additionalProperties: false
        )
        writes!

        def self.perform(user, id:, delta:, reason: "adjusted", note: nil, project: nil)
          i = item!(user, id)
          raise Refused, "delta must not be zero." if delta.zero?

          project_id = project && project!(user, project).id
          txn = Maker::InventoryTransaction.apply!(item: i, user: user, delta: delta, reason: reason,
                                                   project_id: project_id, note: note)
          { item: Render.item(i.reload, full: true), transaction: Render.transaction(txn) }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it, expect green** (6 runs).

- [ ] **Step 5: Mutation checks (report actual output)**

1. In `CreateInventoryItem.perform` delete the `apply!` branch → the ledger assertion goes red. Restore.
2. In `AdjustInventory.perform` delete the `delta.zero?` refusal → that assertion goes red. Restore.
3. In `ListInventory.perform` drop the `low_stock` arm → the low_stock filter assertion goes red. Restore.

- [ ] **Step 6: `bin/rubocop` on both files** → no offenses. Report.

---

### Task 5: BOM tools

**Files:**
- Modify: `app/services/mcp_server/tools/bom.rb` (replace the stub)
- Create: `test/integration/mcp/bom_tools_test.rb`

- [ ] **Step 1: Write the test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  class BomToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @token = bootstrap_token(email: "mcp-bom@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-bom@example.com")
      @lamp = @user.maker_projects.create!(name: "Lamp")
      @bolts = @user.maker_inventory_items.create!(name: "M3 bolt", unit_cost: 0.5)
      Maker::InventoryTransaction.apply!(item: @bolts, user: @user, delta: 2, reason: "initial")
      @bolts.reload
    end

    test "get_bom answers the project's BOMs, the first one's lines, what is short and the cost" do
      bom = @lamp.boms.create!(user: @user)
      stock = bom.lines.create!(user: @user, inventory_item: @bolts, quantity: 4, reference: "R1")
      text = bom.lines.create!(user: @user, part_name: "Lens", quantity: 1, notes: "acrylic")
      @lamp.boms.create!(user: @user, name: "Rev B", revision: 2)

      out = mcp_structured(@token, "get_bom", { project: "lamp" })
      assert_equal [ [ bom.id, 2 ], [ @lamp.boms.last.id, 0 ] ], out["boms"].map { |b| [ b["id"], b["lines"] ] }
      assert_equal bom.id, out.dig("bom", "id")
      lines = out.dig("bom", "lines")
      assert_equal [ stock.id, text.id ], lines.map { |l| l["id"] }
      assert_equal({ "id" => @bolts.id, "name" => "M3 bolt", "on_hand" => 2.0 }, lines.first["item"])
      assert_equal "inventory_item", lines.first["kind"]
      assert_equal "Lens", lines.last["part_name"]
      assert_equal [ { "line_id" => stock.id, "item" => "M3 bolt", "needed" => 4.0, "on_hand" => 2.0 } ], out.dig("bom", "short")
      assert_equal 2.0, out.dig("bom", "estimated_cost")
    end

    test "get_bom takes a bom_id, answers bom: null for a project with none, and names a wrong id" do
      assert_nil mcp_structured(@token, "get_bom", { project: "lamp" })["bom"]
      rev_b = @lamp.boms.create!(user: @user, name: "Rev B", revision: 2)
      assert_equal rev_b.id, mcp_structured(@token, "get_bom", { project: "lamp", bom_id: rev_b.id }).dig("bom", "id")
      assert_equal "No BOM with id 0 on project \"lamp\".", mcp_refusal(@token, "get_bom", { project: "lamp", bom_id: 0 })
    end

    test "add_bom_line creates the project's first BOM, then adds a stock line and a text line" do
      out = mcp_structured(@token, "add_bom_line", { project: "lamp", inventory_item_id: @bolts.id, quantity: 4 })
      bom = @lamp.boms.sole
      assert_equal bom.id, out["bom_id"]
      line = bom.lines.sole
      assert_equal @bolts, line.inventory_item
      assert_equal "each", out.dig("line", "unit")

      out = mcp_structured(@token, "add_bom_line", { project: "lamp", part_name: "Lens", unit: "sheet", notes: "acrylic" })
      assert_equal bom.id, out["bom_id"]
      assert_equal 2, bom.lines.count
      assert_equal 1.0, out.dig("line", "quantity")
    end

    test "add_bom_line refuses a line with no target or two targets in the model's words" do
      assert_match(/exactly one of/, mcp_refusal(@token, "add_bom_line", { project: "lamp" }))
      assert_match(/exactly one of/, mcp_refusal(@token, "add_bom_line", { project: "lamp", inventory_item_id: @bolts.id, part_name: "Lens" }))
      assert_empty @lamp.boms.sole.lines
    end

    test "update_bom_line changes the given fields" do
      bom = @lamp.boms.create!(user: @user)
      line = bom.lines.create!(user: @user, part_name: "Lens", quantity: 1)
      out = mcp_structured(@token, "update_bom_line", { id: line.id, quantity: 3, reference: "L1" })
      assert_equal [ 3, "L1", "Lens" ], [ line.reload.quantity.to_i, line.reference, line.part_name ]
      assert_equal 3.0, out.dig("line", "quantity")
      assert_equal "No BOM line with id 0.", mcp_refusal(@token, "update_bom_line", { id: 0, quantity: 1 })
    end
  end
end
```

- [ ] **Step 2: Run it, expect red.**

- [ ] **Step 3: Write the module**

```ruby
# frozen_string_literal: true

module McpServer
  module Tools
    # THE BILL OF MATERIALS: read one with its rollup (Maker::BomRollup, over lines loaded WITH their
    # items so it issues no query), add a line, change a line. A line's target rules are the
    # model's (Maker::BomLine#exactly_one_target), answered in its own words.
    module Bom
      def self.all = [ GetBom, AddBomLine, UpdateBomLine ]

      LINE_FIELDS = {
        quantity: { type: "number", exclusiveMinimum: 0 },
        unit: { type: "string", enum: Maker::BomLine::UNITS },
        reference: { type: "string", maxLength: 100 },
        notes: { type: "string" },
        part_name: { type: "string", maxLength: 200, description: "A free-text part, for a line with no inventory item." },
        inventory_item_id: { type: "integer", description: "A stock line, counted in the item's unit." },
        supplier_id: { type: "integer" }
      }.freeze

      class GetBom < McpServer::Tool
        tool_name "get_bom"
        description "A project's bill of materials: every BOM it has, and the lines of one of them " \
                    "(bom_id, else the first) -- each line's target (an inventory item with stock on " \
                    "hand, a free-text part, or a design file), which stock lines are short, and the " \
                    "estimated cost."
        input_schema(
          properties: { project: { type: "string", description: "The project's slug." }, bom_id: { type: "integer" } },
          required: %w[project], additionalProperties: false
        )
        reads!

        def self.perform(user, project:, bom_id: nil)
          p = project!(user, project)
          boms = p.boms.order(:id).to_a
          counts = Maker::BomLine.where(bom_id: boms.map(&:id)).group(:bom_id).count
          bom = bom_id ? boms.find { |b| b.id == bom_id } : boms.first
          raise NotFound, "No BOM with id #{bom_id} on project #{p.slug.inspect}." if bom_id && bom.nil?

          answer = { project: p.slug, boms: boms.map { |b| Render.bom(b, lines: counts.fetch(b.id, 0)) } }
          return answer.merge(bom: nil) if bom.nil?

          lines = bom.lines.includes(:inventory_item, :supplier).to_a
          rollup = Maker::BomRollup.new(lines)
          answer.merge(bom: Render.bom(bom, lines: lines.size).merge(
            lines: lines.map { |l| Render.line(l) },
            short: rollup.short.map do |s|
              { line_id: s.line.id, item: s.line.inventory_item.name,
                needed: Render.number(s.line.quantity), on_hand: Render.number(s.on_hand) }
            end,
            estimated_cost: Render.number(rollup.estimated_cost)
          ))
        end
      end

      class AddBomLine < McpServer::Tool
        tool_name "add_bom_line"
        description "Add a line to a project's BOM (its first, or bom_id). Exactly one of " \
                    "inventory_item_id (a stock line, counted in the item's unit) or part_name (a " \
                    "free-text part). A project with no BOM gets one. quantity defaults to 1."
        input_schema(
          properties: { project: { type: "string", description: "The project's slug." }, bom_id: { type: "integer" } }.merge(LINE_FIELDS),
          required: %w[project], additionalProperties: false
        )
        writes!

        def self.perform(user, project:, bom_id: nil, **fields)
          p = project!(user, project)
          bom =
            if bom_id
              p.boms.find_by(id: bom_id) || raise(NotFound, "No BOM with id #{bom_id} on project #{p.slug.inspect}.")
            else
              p.boms.order(:id).first || p.boms.create!(user: user)
            end
          line = bom.lines.create!(fields.merge(user: user))
          { bom_id: bom.id, line: Render.line(line) }
        end
      end

      class UpdateBomLine < McpServer::Tool
        tool_name "update_bom_line"
        description "Change a BOM line's quantity, unit, reference, notes, part name, inventory item " \
                    "or supplier; only the fields given change."
        input_schema(
          properties: { id: { type: "integer" } }.merge(LINE_FIELDS),
          required: %w[id], additionalProperties: false
        )
        writes!(idempotent: true)

        def self.perform(user, id:, **fields)
          line = bom_line!(user, id)
          line.update!(fields)
          { line: Render.line(line) }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it, expect green** (5 runs).

- [ ] **Step 5: Mutation checks (report actual output)**

1. In `GetBom.perform` replace `rollup.short.map do … end` with `[]` → the short assertion goes red. Restore.
2. In `AddBomLine.perform` replace `p.boms.create!(user: user)` with `raise(NotFound, "none")` → the first-BOM test goes red. Restore.

- [ ] **Step 6: `bin/rubocop` on both files** → no offenses. Report.

---

### Task 6: Reference tools (suppliers, locations)

**Files:**
- Modify: `app/services/mcp_server/tools/reference.rb` (replace the stub)
- Create: `test/integration/mcp/reference_tools_test.rb`

- [ ] **Step 1: Write the test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  class ReferenceToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @token = bootstrap_token(email: "mcp-reference@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-reference@example.com")
    end

    test "list_suppliers and create_supplier" do
      @user.maker_suppliers.create!(name: "Zed parts", url: "https://zed.example")
      @user.maker_suppliers.create!(name: "Acme")
      out = mcp_structured(@token, "list_suppliers")
      assert_equal [ "Acme", "Zed parts" ], out["suppliers"].map { |s| s["name"] }
      assert_equal "https://zed.example", out["suppliers"].last["url"]

      out = mcp_structured(@token, "create_supplier", { name: "Bolt barn", notes: "cheap" })
      assert_equal "cheap", @user.maker_suppliers.find(out.dig("supplier", "id")).notes
      assert_match(/Name can't be blank/, mcp_refusal(@token, "create_supplier", { name: " " }))
    end

    test "list_locations names the parent, and create_location nests" do
      shop = @user.maker_locations.create!(name: "Shop")
      @user.maker_locations.create!(name: "Bench", parent: shop)
      out = mcp_structured(@token, "list_locations")
      assert_equal [ [ "Bench", "Shop" ], [ "Shop", nil ] ], out["locations"].map { |l| [ l["name"], l["parent"] ] }

      out = mcp_structured(@token, "create_location", { name: "Drawer 3", parent_id: shop.id, description: "screws" })
      drawer = @user.maker_locations.find(out.dig("location", "id"))
      assert_equal shop, drawer.parent
      assert_equal "Shop", out.dig("location", "parent")

      other = User.create!(email: "other-loc@example.com", confirmed_at: Time.current, omniauth_signup: true)
      theirs = other.maker_locations.create!(name: "Theirs")
      assert_match(/Parent/i, mcp_refusal(@token, "create_location", { name: "X", parent_id: theirs.id }))
    end
  end
end
```

- [ ] **Step 2: Run it, expect red.**

- [ ] **Step 3: Write the module**

```ruby
# frozen_string_literal: true

module McpServer
  module Tools
    # REFERENCE DATA: suppliers and locations, listed and added. Both are small per user, so no cap.
    module Reference
      def self.all = [ ListSuppliers, CreateSupplier, ListLocations, CreateLocation ]

      class ListSuppliers < McpServer::Tool
        tool_name "list_suppliers"
        description "Every supplier, by name: id, name, url, notes."
        input_schema(properties: {}, required: [], additionalProperties: false)
        reads!

        def self.perform(user)
          { suppliers: user.maker_suppliers.order(:name, :id).map { |s| Render.supplier(s) } }
        end
      end

      class CreateSupplier < McpServer::Tool
        tool_name "create_supplier"
        description "Add a supplier."
        input_schema(
          properties: { name: { type: "string", minLength: 1, maxLength: 200 }, url: { type: "string", maxLength: 500 }, notes: { type: "string" } },
          required: %w[name], additionalProperties: false
        )
        writes!

        def self.perform(user, name:, url: nil, notes: nil)
          { supplier: Render.supplier(user.maker_suppliers.create!(name: name, url: url, notes: notes)) }
        end
      end

      class ListLocations < McpServer::Tool
        tool_name "list_locations"
        description "Every storage location, by name: id, name, parent (name and id), description."
        input_schema(properties: {}, required: [], additionalProperties: false)
        reads!

        def self.perform(user)
          { locations: user.maker_locations.includes(:parent).order(:name, :id).map { |l| Render.location(l) } }
        end
      end

      class CreateLocation < McpServer::Tool
        tool_name "create_location"
        description "Add a storage location, optionally inside another (parent_id)."
        input_schema(
          properties: { name: { type: "string", minLength: 1, maxLength: 200 }, parent_id: { type: "integer" }, description: { type: "string" } },
          required: %w[name], additionalProperties: false
        )
        writes!

        def self.perform(user, name:, parent_id: nil, description: nil)
          { location: Render.location(user.maker_locations.create!(name: name, parent_id: parent_id, description: description)) }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it, expect green** (2 runs).

- [ ] **Step 5: Mutation checks (report actual output):** (1) in `ListLocations.perform` change `order(:name, :id)` to `order(:id)` → the name-order assertion goes red; restore. (2) In `Render.location` (Task 1's file, restore it after) change `parent: l.parent&.name` to `parent: nil` → the `[ "Bench", "Shop" ]` assertion goes red; restore.

- [ ] **Step 6: `bin/rubocop` on both files** → no offenses. Report.

---

### Task 7: Library tools (list_folder, read_text_file, search)

**Files:**
- Modify: `app/services/mcp_server/tools/library.rb` (replace the stub)
- Create: `test/integration/mcp/library_tools_test.rb`

- [ ] **Step 1: Write the test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  # ON A FRESH SHARE LIBRARY, LIKE markdown_file_page_test.rb: the rows AND the bytes are this test's
  # own, so the three backend legs run the same tests and the RUN counts stay equal (§15).
  class LibraryToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    LIMIT = McpServer::Tools::Library::READ_LIMIT

    setup do
      @root = use_fresh_share_library!
      @token = bootstrap_token(email: "mcp-library@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-library@example.com")
      @projects = dir!("Projects", nil)
      @lamp = dir!("lamp", @projects)
      @readme = file!("README.md", @lamp, "# Lamp\n\nA desk lamp.\n")
      @lid = file!("lid.stl", @lamp, "solid lid")
      file!(".DS_Store", @lamp, "x")
      dir!("models", @lamp)
    end

    def dir!(name, parent)
      create_node!(@user, node_id: SecureRandom.uuid, name: name, kind: "dir",
                          parent_node_id: parent&.node_id, mtime: 1_700_000_000_000_000_000, size: 0)
    end

    # create_node! writes a placeholder at the storage_path it computes; the body goes over it.
    def file!(name, parent, body)
      node = create_node!(@user, node_id: SecureRandom.uuid, name: name, kind: "file", parent_node_id: parent&.node_id,
                                 mtime: 1_700_000_000_000_000_000, size: body.bytesize,
                                 content_hash: Digest::SHA256.hexdigest(body))
      @root.join(node.storage_path).binwrite(body)
      node
    end

    test "list_folder answers the root, then a folder with folders first, hidden files left out, paths and text flags" do
      out = mcp_structured(@token, "list_folder")
      assert_equal "", out["path"]
      assert_equal [ [ "Projects", "dir", "Projects" ] ], out["entries"].map { |e| [ e["name"], e["kind"], e["path"] ] }

      out = mcp_structured(@token, "list_folder", { path: "/Projects/lamp/" })
      assert_equal "Projects/lamp", out["path"]
      assert_equal %w[models README.md lid.stl], out["entries"].map { |e| e["name"] }
      readme = out["entries"].find { |e| e["name"] == "README.md" }
      assert_equal "Projects/lamp/README.md", readme["path"]
      assert_equal true, readme["text"]
      assert_equal false, out["entries"].last["text"]
      assert_equal "2023-11-14T22:13:20Z", readme["modified_at"]
      assert_equal @readme.node_id, readme["node_id"]
      assert_equal false, out["truncated"]
    end

    test "list_folder refuses a file, names a missing path, and refuses dot segments" do
      assert_match(/is a file/, mcp_refusal(@token, "list_folder", { path: "Projects/lamp/README.md" }))
      assert_equal "No file or folder at \"Projects/nope\".", mcp_refusal(@token, "list_folder", { path: "Projects/nope" })
      assert_match(/no "\." or "\.\." segments/, mcp_refusal(@token, "list_folder", { path: "Projects/../etc" }))
    end

    test "read_text_file answers the bytes of a text file as UTF-8" do
      out = mcp_structured(@token, "read_text_file", { path: "Projects/lamp/README.md" })
      assert_equal "# Lamp\n\nA desk lamp.\n", out["text"]
      assert_equal [ "Projects/lamp/README.md", @readme.node_id, 21 ], [ out["path"], out["node_id"], out["size"] ]
    end

    test "read_text_file refuses a folder, the root, a binary file, and a missing path" do
      assert_match(/is a folder/, mcp_refusal(@token, "read_text_file", { path: "Projects/lamp" }))
      assert_match(/library root/, mcp_refusal(@token, "read_text_file", { path: "/" }))
      assert_equal "lid.stl is not text (its kind is Models); read_text_file only reads text files.",
                   mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/lid.stl" })
      assert_equal "No file or folder at \"Projects/lamp/x.md\".", mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/x.md" })
    end

    test "read_text_file refuses a file over the cap BEFORE reading it, and one that grew past it after" do
      big = file!("big.txt", @lamp, "x" * (LIMIT + 1))
      replacing(FileLayer.current, :read, ->(*, **) { flunk "read must not run for a file the catalog already knows is too big" }) do
        assert_match(/#{LIMIT + 1} bytes/, mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/big.txt" }))
      end
      big.update_column(:size, 10)
      assert_match(/bytes/, mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/big.txt" }))
    end

    test "read_text_file answers the unreachable sentence when the store is down, and scrubs bad UTF-8" do
      replacing(FileLayer.current, :read, ->(*, **) { raise FileLayer::FetchError, "mount gone" }) do
        assert_equal McpServer::Tool::UNREACHABLE, mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/README.md" })
      end
      file!("notes.txt", @lamp, "ok \xFF bad".b)
      assert_equal "ok � bad", mcp_structured(@token, "read_text_file", { path: "Projects/lamp/notes.txt" })["text"]
    end

    test "search answers files, folders, projects and inventory in one call, with paths" do
      @user.maker_projects.create!(name: "Lamp stand")
      @user.maker_inventory_items.create!(name: "Lamp cord")
      out = mcp_structured(@token, "search", { q: "LAMP" })
      assert_equal [ "Projects/lamp" ], out["folders"].map { |f| f["path"] }
      assert_equal [], out["files"]
      assert_equal [ "lamp-stand" ], out["projects"].map { |p| p["slug"] }
      assert_equal [ "Lamp cord" ], out["inventory"].map { |i| i["name"] }

      out = mcp_structured(@token, "search", { q: "lid" })
      assert_equal [ "Projects/lamp/lid.stl" ], out["files"].map { |f| f["path"] }
      assert_equal "lid", out["q"]
    end
  end
end
```

(The `modified_at` value is `1_700_000_000` seconds = 2023-11-14T22:13:20Z; the nanos literal above is that times 10^9. The role label for `.stl` is `Maker::FileAttachment::ROLE_LABELS["model"]`, which is "Models".)

- [ ] **Step 2: Run it, expect red.**

- [ ] **Step 3: Write the module**

```ruby
# frozen_string_literal: true

module McpServer
  module Tools
    # THE LIBRARY TREE AND ITS TEXT (spec §4, §5): a folder's entries, one text file's bytes, and one
    # search across everything. The tree is read from the catalog alone (LibraryPath); the ONE port
    # read is the bytes of the one file the model asked for, bounded by the catalog's size first --
    # the same allowance Maker::MarkdownFile has on a GET, and the same cap (§2, §14a).
    module Library
      def self.all = [ ListFolder, ReadTextFile, Search ]

      FOLDER_CAP = 500
      READ_LIMIT = Maker::Readme::READ_LIMIT

      class ListFolder < McpServer::Tool
        tool_name "list_folder"
        description "The files and folders directly inside one folder of the library (the root when " \
                    "path is omitted), folders first. Hidden files, the .git marker and build output " \
                    "are left out, as on the Files page. Each entry carries the path the other tools " \
                    "take, and text: true where read_text_file can read it. At most #{FOLDER_CAP}."
        input_schema(properties: { path: { type: "string", maxLength: 2000 } }, required: [], additionalProperties: false)
        reads!

        def self.perform(user, path: "")
          node = LibraryPath.resolve!(user, path)
          raise Refused, "#{path.inspect} is a file; list its folder, or read it with read_text_file." if node && !node.dir?

          base = LibraryPath.normalize(path)
          scope = user.nodes.present.visible_entries(false).where(parent_node_id: node&.node_id)
                      .order(Arel.sql("CASE kind WHEN 'dir' THEN 0 ELSE 1 END"), :name)
          rows, truncated = capped(scope, FOLDER_CAP)
          { path: base, entries: rows.map { |n| Render.node(n, path: LibraryPath.join(base, n.name)) }, truncated: }
        end
      end

      class ReadTextFile < McpServer::Tool
        tool_name "read_text_file"
        description "The text of one file, by path: README and Markdown, source code, config, G-code, " \
                    "SCAD, CSV, logs -- anything the library classes as text. Refuses binary files " \
                    "(models, images, CAD) and files over #{READ_LIMIT} bytes."
        input_schema(properties: { path: { type: "string", maxLength: 2000 } }, required: %w[path], additionalProperties: false)
        reads!

        def self.perform(user, path:)
          node = LibraryPath.resolve!(user, path)
          raise Refused, "Give a file's path; the library root is a folder (list_folder)." if node.nil?
          raise Refused, "#{path.inspect} is a folder; list it with list_folder." if node.dir?
          unless Maker::FileAttachment.text?(node.name)
            label = Maker::FileAttachment::ROLE_LABELS.fetch(Maker::FileAttachment.role_for(node.name), "Other")
            raise Refused, "#{node.name} is not text (its kind is #{label}); read_text_file only reads text files."
          end
          raise Refused, too_large(node.name, node.size.to_i) if node.size.to_i > READ_LIMIT

          bytes = FileLayer.current.read(user, node_id: node.node_id)
          # THE CATALOG CAN LAG THE STORE (a share file grown since the last scan): measured again.
          raise Refused, too_large(node.name, bytes.bytesize) if bytes.bytesize > READ_LIMIT

          text = bytes.dup.force_encoding(Encoding::UTF_8).scrub
          { path: LibraryPath.normalize(path), node_id: node.node_id, size: bytes.bytesize, text: text }
        end

        def self.too_large(name, size)
          "#{name} is #{size} bytes; read_text_file reads files up to #{READ_LIMIT} bytes."
        end
      end

      class Search < McpServer::Tool
        PER_KIND = 5
        QUERY_MAX = 80

        tool_name "search"
        description "Search everything at once by a name substring: files, folders, projects and " \
                    "inventory items, up to #{PER_KIND} of each. Use list_folder, get_project or " \
                    "get_inventory_item to go deeper."
        input_schema(properties: { q: { type: "string", minLength: 1, maxLength: QUERY_MAX } }, required: %w[q], additionalProperties: false)
        reads!

        def self.perform(user, q:)
          q = q.to_s.strip.first(QUERY_MAX)
          raise Refused, "Give something to search for." if q.blank?

          tree = Maker::LibraryTree.new(user)
          pattern = like(Node, q)
          nodes = user.nodes.present.visible_entries(false).where("LOWER(name) LIKE ? ESCAPE '\\'", pattern).order(:name)
          files = nodes.where(kind: "file").limit(PER_KIND).to_a
          folders = nodes.where(kind: "dir").limit(PER_KIND).to_a
          projects = user.maker_projects
                         .where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(slug) LIKE ? ESCAPE '\\'", pattern, pattern)
                         .order(:name).limit(PER_KIND).to_a
          items = user.maker_inventory_items.includes(:location, :supplier)
                      .where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(COALESCE(part_number, '')) LIKE ? ESCAPE '\\'", pattern, pattern)
                      .order(:name).limit(PER_KIND).to_a
          { q: q,
            files: files.map { |n| Render.node(n, path: LibraryPath.of(tree, n)) },
            folders: folders.map { |n| Render.node(n, path: LibraryPath.of(tree, n)) },
            projects: projects.map { |p| Render.project(p, tree:) },
            inventory: items.map { |i| Render.item(i) } }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run it, expect green** (7 runs). Delete the `if false` line from the search test before reporting; it is a placeholder for the echoed query and the next line is the real assertion.

- [ ] **Step 5: Mutation checks (report actual output)**

1. In `LibraryPath.segments` delete the `.`/`..` refusal → the dot-segment refusal goes red. Restore.
2. In `ReadTextFile.perform` delete the size check BEFORE the read → "refuses a file over the cap BEFORE reading it" flunks inside the stub. Restore.
3. In `ListFolder.perform` change `visible_entries(false)` to `visible_entries(true)` → `.DS_Store` appears and the names assertion goes red. Restore.

- [ ] **Step 6: `bin/rubocop` on both files** → no offenses. Report.

---

### Task 8: The token door on Settings → Devices

**Files:**
- Modify: `config/routes.rb` — in `namespace :settings`, change `resources :devices, only: %i[index destroy]` to `resources :devices, only: %i[index create destroy]`
- Modify: `app/controllers/settings/devices_controller.rb`
- Modify: `app/views/settings/devices/index.html.erb`
- Create: `app/views/settings/devices/connected.html.erb`
- Modify: `app/assets/stylesheets/pages/settings.css`
- Create: `test/integration/web/settings_devices_connect_test.rb`

Read `docs/invariants/design-system.md` rules 3, 9, 10, 11, 13 before touching the views.

- [ ] **Step 1: Write the test**

```ruby
require "test_helper"
require "support/mcp_client"

module Web
  # CONNECT AN AI ASSISTANT (spec 2026-11-04-mcp-server-design §6): the form, the once-shown token,
  # that the token opens /mcp, that the demo is refused, and that Sign out revokes it.
  class SettingsDevicesConnectTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @user = User.create!(email: "connect@example.com", password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
    end

    # The v1 device-login tests' idiom: Tinkerex::Demo reads the variable per call.
    def with_demo(email)
      prior = ENV.fetch("DEMO_ACCOUNT_EMAIL", nil)
      ENV["DEMO_ACCOUNT_EMAIL"] = email
      yield
    ensure
      prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
    end

    test "the Devices page offers the connect form with the field name the controller reads" do
      get settings_devices_path
      assert_response :success
      assert_select "form[action=?][data-turbo=false]", settings_devices_path do
        assert_select "input[name=?][value=?]", "device[name]", Settings::DevicesController::DEFAULT_ASSISTANT_NAME
        assert_select "input[type=submit][value=Connect]"
      end
      assert_select "p.muted", text: /desktop apps and assistants/
    end

    test "connecting mints a device with no sync grant, shows the token once, and the token opens /mcp" do
      assert_difference -> { @user.devices.count }, 1 do
        post settings_devices_path, params: { device: { name: "Claude Code" } }
      end
      assert_response :success
      device = @user.devices.order(:id).last
      assert_equal "Claude Code", device.name
      assert_nil device.sync_device_id

      token = css_select("code.connect-secret").first.text.strip
      assert_equal device.token_digest, Device.digest(token), "the page shows the plaintext whose digest was stored"
      assert_select "[data-controller=copy][data-copy-text-value=?]", token
      command = "claude mcp add --transport http tinkerex http://www.example.com/mcp --header \"Authorization: Bearer #{token}\""
      assert_select "[data-copy-text-value=?]", command
      assert_select "pre", text: /"url": "http:\/\/www.example.com\/mcp"/
      assert_empty flash.to_h, "the token must never pass through the flash"

      assert_equal({}, mcp_rpc(token, "ping")["result"])
    end

    test "a blank name falls back to the default" do
      post settings_devices_path, params: { device: { name: "   " } }
      assert_equal Settings::DevicesController::DEFAULT_ASSISTANT_NAME, @user.devices.order(:id).last.name
    end

    test "the demo account is refused with no row" do
      with_demo(@user.email) do
        assert_no_difference -> { Device.count } do
          post settings_devices_path, params: { device: { name: "x" } }
        end
        assert_redirected_to settings_devices_path
        assert_match(/demo/, flash[:alert])
      end
    end

    test "the connected assistant lists on the Devices page and Sign out revokes its token" do
      post settings_devices_path, params: { device: { name: "Claude Code" } }
      token = css_select("code.connect-secret").first.text.strip
      device = @user.devices.order(:id).last

      get settings_devices_path
      assert_select ".settings-list li .settings-name", text: "Claude Code"

      delete settings_device_path(device)
      assert_redirected_to settings_devices_path
      mcp_post(token, { jsonrpc: "2.0", id: 1, method: "ping" })
      assert_response :unauthorized
    end
  end
end
```

- [ ] **Step 2: Run it, expect red** (no route for POST).

- [ ] **Step 3: The route** — edit the `resources :devices` line inside `namespace :settings` as the Files list says, and change its comment to: `# YOUR OWN DEVICES (pentest H1b, 2026-10-22; assistants 2026-11-04): the list, Connect an assistant, and Sign out per row.`

- [ ] **Step 4: The controller**

Replace `app/controllers/settings/devices_controller.rb` with:

```ruby
# YOUR DESKTOP DEVICES AND ASSISTANTS (pentest H1b, tinkerex#465; docs/superpowers/plans/2026-10-22-device-token-lifecycle.md;
# assistants: docs/superpowers/specs/2026-11-04-mcp-server-design.md §6).
# Each row is one holder of a device token: a desktop app signed in to this account, or an AI
# assistant connected here. Signing one out deletes the row, which refuses that token at its next
# request. An admin does the same for another account on Settings → Users
# (Settings::UsersController#revoke_device).
#
# SESSION-AUTHED, NEVER THE DEVICE API (§14d). A stolen token must not be able to list the account's
# other devices, keep itself alive by signing the real one out, or mint a sibling for itself.
module Settings
  class DevicesController < ApplicationController
    # The name an assistant row gets when the form's field is left blank.
    DEFAULT_ASSISTANT_NAME = "AI assistant".freeze

    # Most recently used first, which is the order someone looking for a lost laptop reads in.
    # Sorted in Ruby on Device#last_active_at, the one definition of the idle clock.
    def index
      @devices = current_user.devices.to_a.sort_by(&:last_active_at).reverse
      @idle_limit = Device.idle_limit
    end

    # POST /settings/devices {device: {name}} -- CONNECT AN AI ASSISTANT. Mints a Device with NO sync
    # grant: an MCP client never syncs, and a dead sync server must not block connecting one
    # (V1::DevicesController's 503 rule is for devices that will sync). The token is RENDERED ONCE,
    # on this response, never through a redirect: a flash lives in the session cookie, and the
    # plaintext must not. The demo is refused before anything is minted, as both v1 doors refuse it.
    def create
      if Tinkerex::Demo.demo?(current_user)
        return redirect_to settings_devices_path, status: :see_other,
                           alert: "Refused: the shared demo account cannot connect an assistant."
      end

      name = params.fetch(:device, {}).permit(:name)[:name].to_s.strip.first(80).presence || DEFAULT_ASSISTANT_NAME
      @device = Device.register!(user: current_user, name: name)
      @token = @device.plaintext_token
      @mcp_url = "#{request.base_url}/mcp"
      render :connected
    end

    # SCOPED THROUGH current_user, NEVER Device.find: a foreign id must 404, not sign out someone
    # else's laptop (Settings::TagsController#destroy makes the same argument).
    def destroy
      device = current_user.devices.find(params[:id])
      device.destroy!
      redirect_to settings_devices_path, status: :see_other,
                  notice: "Signed out #{device.name}. It needs your password to sign in again."
    end
  end
end
```

- [ ] **Step 5: The index view**

In `app/views/settings/devices/index.html.erb` replace the first `<p class="muted">` (the one beginning "The desktop apps signed in") with:

```erb
<p class="muted">
  The desktop apps and assistants connected to your account, most recently used first. Sign one
  out when you stop using it, or as soon as it is lost.
</p>
```

and replace the empty-list line `<li class="empty inline">No desktop app is signed in to this account.</li>` with `<li class="empty inline">Nothing is connected to this account.</li>`. Then append at the end of the file:

```erb

<h2>Connect an AI assistant</h2>
<p class="muted">
  Claude Code, Claude Desktop or any MCP client can work in this library through a token of its
  own, made here and shown once. It appears in the list above and is signed out the same way.
</p>
<%# scope: :device -- form_with url: has no model, so scope: is what names the field device[name],
    which Settings::DevicesController#create reads (CLAUDE.md §14d). The value is stated, because a
    scoped field with no model falls back to an @device this page never sets. Turbo is off on this
    form: the answer is a page carrying a secret shown once, rendered rather than redirected to, and
    a full page load is the one shape every Turbo version renders. The submit is a quiet button:
    this page has no accent (design-system.md rule 13). %>
<%= form_with url: settings_devices_path, scope: :device, class: "settings-add", data: { turbo: false } do |f| %>
  <label>
    <span>Name</span>
    <%= f.text_field :name, value: Settings::DevicesController::DEFAULT_ASSISTANT_NAME, required: true,
                     maxlength: 80, autocomplete: "off" %>
  </label>
  <%= f.submit "Connect", class: "btn" %>
<% end %>
```

- [ ] **Step 6: The connected view**

Create `app/views/settings/devices/connected.html.erb`:

```erb
<% content_for :title, "Assistant connected — Tinkerex" %>
<%= render "settings/crumbs", current: "Assistant connected", trail: [ [ "Devices", settings_devices_path ] ] %>

<%# THE TOKEN, ONCE (Settings::DevicesController#create). Every secret and snippet carries its own
    copy button (copy_controller.js, which works on a plain-http LAN too). The command line is for
    Claude Code; the JSON is the shape other clients read; claude.ai's hosted connectors need OAuth,
    which this server does not offer, and the page says so rather than let someone try. %>
<div class="page-head">
  <h1>Connected <%= @device.name %></h1>
</div>

<p class="muted">
  This token is shown once. Paste it into your client now. If it is lost, sign this assistant out
  on the Devices page and connect it again.
</p>

<dl class="meta connect-steps">
  <dt>Token</dt>
  <dd data-controller="copy" data-copy-text-value="<%= @token %>">
    <code class="connect-secret" data-copy-target="source"><%= @token %></code>
    <button type="button" class="btn small" data-action="copy#copy">Copy</button>
  </dd>

  <dt>Claude Code</dt>
  <% command = "claude mcp add --transport http tinkerex #{@mcp_url} --header \"Authorization: Bearer #{@token}\"" %>
  <dd data-controller="copy" data-copy-text-value="<%= command %>">
    <pre class="connect-cmd" data-copy-target="source"><%= command %></pre>
    <button type="button" class="btn small" data-action="copy#copy">Copy</button>
  </dd>

  <dt>Other MCP clients</dt>
  <% json = JSON.pretty_generate("mcpServers" => { "tinkerex" => { "type" => "http", "url" => @mcp_url,
                                                                    "headers" => { "Authorization" => "Bearer #{@token}" } } }) %>
  <dd data-controller="copy" data-copy-text-value="<%= json %>">
    <pre class="connect-cmd" data-copy-target="source"><%= json %></pre>
    <button type="button" class="btn small" data-action="copy#copy">Copy</button>
  </dd>
</dl>

<p class="muted">
  Works with Claude Code, Claude Desktop (through a local MCP config) and any client that can send
  a header. claude.ai's hosted connectors need OAuth, which this server does not offer. The
  assistant is signed out like any device, and changing your password signs out every one.
</p>

<p><%= link_to "Back to Devices", settings_devices_path, class: "btn" %></p>
```

- [ ] **Step 7: The stylesheet**

In `app/assets/stylesheets/pages/settings.css`, inside the `@layer pages { … }` block, after the `.settings-add > .form-errors` rule, add:

```css
  /* CONNECT AN ASSISTANT (2026-11-04): a token and two snippets, each beside its Copy. A token is
     one unbroken run and a command line is long, so both wrap ANYWHERE (design-system.md rule 11:
     nothing scrolls sideways at 375px) and keep their mono. `dl.meta` is the component; only its
     children are styled here. */
  .connect-steps dd { display: flex; flex-wrap: wrap; align-items: start; gap: 8px; }
  .connect-secret, .connect-cmd { font-family: var(--font-mono); font-size: 12px; overflow-wrap: anywhere; white-space: pre-wrap; margin: 0; flex: 1 1 240px; min-width: 0; }
```

- [ ] **Step 8: Run the test, expect green** (5 runs). Then run the guards this touches:

`bin/rails test test/integration/web/notice_grammar_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb test/no_emoji_test.rb test/integration/web/settings_devices_test.rb test/integration/web/time_format_test.rb` → all green. (If `settings_devices_test.rb` asserts the old "desktop apps signed in" sentence or the old empty-list sentence, update that assertion to the new copy in the same task — grep `test/` for both old sentences.)

- [ ] **Step 9: Mutation checks (report actual output)**

1. In `create`, change `render :connected` to `redirect_to settings_devices_path, notice: @token` → the flash-empty assertion and the token assertions go red. Restore.
2. In `create`, delete the demo refusal → the demo test goes red. Restore.
3. In the index view, change `scope: :device` to `scope: :assistant` → the field-name assertion goes red. Restore.

- [ ] **Step 10: `bin/rubocop`** on the controller and test → no offenses. Report.

---

### Task 9: Docs

**Files:**
- Create: `docs/mcp.md`
- Modify: `docs/README.md` only if it indexes the files in `docs/` (add one line beside `addon-api-v1.md`'s); otherwise leave it.

- [ ] **Step 1: Write `docs/mcp.md`**

```markdown
# Working in a library from an AI assistant (MCP)

Tinkerex serves a [Model Context Protocol](https://modelcontextprotocol.io) server at `POST /mcp`
on every deployment. An MCP client — Claude Code, Claude Desktop, or any other — can read and
change your projects, tasks, build log, inventory and bills of materials, and browse the library's
folders and read its text files. It cannot delete anything, upload anything, or read binary files.

## Connect a client

1. Sign in, open **Settings → Devices**, and under **Connect an AI assistant** give the assistant a
   name and press **Connect**. The next page shows a token **once**, with a ready-made command and
   a JSON snippet.
2. **Claude Code**: paste the command. It has this shape:

   ```
   claude mcp add --transport http tinkerex https://your-server/mcp --header "Authorization: Bearer <token>"
   ```

3. **Other clients** that read an `mcpServers` JSON config: paste the snippet, which has this shape:

   ```json
   { "mcpServers": { "tinkerex": { "type": "http", "url": "https://your-server/mcp",
                                   "headers": { "Authorization": "Bearer <token>" } } } }
   ```

   Claude Desktop reads local (stdio) servers only; bridge it with a local proxy such as
   `mcp-remote`, passing the same URL and header.

4. **claude.ai's hosted connectors** need OAuth, which this server does not offer yet.

The assistant appears on the Devices page like a desktop app, with the same idle expiry
(`DEVICE_IDLE_DAYS`, 90 by default), and **Sign out** there revokes its token at once. Changing your
password signs out every device and assistant. The shared demo account cannot connect one.

## What the assistant can do

Identifiers: a project by its **slug**; a task, inventory item, BOM, BOM line, supplier or location
by the **id** a listing returns; a file or folder by its **library-relative path**
(`Projects/lamp/README.md`). Listings are capped and say `truncated: true` when they were cut.

| tool | does |
|---|---|
| `list_projects(status?, q?)` | projects newest change first, with folder path and open task count |
| `get_project(slug)` | one project: tasks, last 20 build-log entries, BOMs, attached files |
| `create_project(name, …)` | a project and its `Projects/<slug>` folder |
| `update_project(slug, …)` | name, description, status (`archived` archives), kind |
| `list_tasks(project?, status?)` | tasks, open first |
| `create_task(project, title, …)`, `update_task(id, …)` | tasks; `done` stamps completion |
| `list_build_log(project, limit?)` | entries newest first, plain text |
| `add_build_log_entry(project, body, …)` | a note or milestone; plain text in |
| `list_inventory(q?, low_stock?, location_id?)` | items with stock, unit, location, supplier |
| `get_inventory_item(id)` | one item and its last 20 ledger rows |
| `create_inventory_item(name, …)`, `update_inventory_item(id, …)` | items; the opening quantity posts to the ledger |
| `adjust_inventory(id, delta, …)` | a signed stock change, with a reason and a project |
| `get_bom(project, bom_id?)` | a BOM's lines, what is short, the estimated cost |
| `add_bom_line(project, …)`, `update_bom_line(id, …)` | stock lines (by item) or free-text lines |
| `list_suppliers`, `create_supplier(name, …)` | suppliers |
| `list_locations`, `create_location(name, …)` | storage locations |
| `list_folder(path?)` | a folder's entries, folders first, hidden files left out |
| `read_text_file(path)` | a text file's contents, up to 256 KB |
| `search(q)` | files, folders, projects and inventory, five of each |

## How it is built

The endpoint is stateless: one JSON-RPC message per POST, no session, no server-sent events. The
credential is the same device token the v1 API uses, so a revoked or idle device is a 401. Tools
call the app's own models; nothing goes through the HTTP API a second time. The design and its
reasons are in `docs/superpowers/specs/2026-11-04-mcp-server-design.md`.
```

- [ ] **Step 2:** `grep -n "addon-api-v1" docs/README.md`; if it lists docs, add `- [mcp.md](mcp.md) — connecting an AI assistant and the tools it gets` beside it. Report whether you did.

---

### Task 10: The cross-cutting guards and the invariant (after Tasks 2–9)

**Files:**
- Create: `test/integration/mcp/catalog_test.rb`
- Create: `test/integration/mcp/isolation_test.rb`
- Create: `test/integration/mcp/query_budget_test.rb`
- Modify: `CLAUDE.md` (§14d, after the `Current.library_unreachable` bullet, i.e. the last bullet of §14d)
- Modify: `test/docs_hygiene_test.rb` (`MAX_LINES`)

- [ ] **Step 1: The catalog test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  # THE CATALOG AS THE CLIENT SEES IT (spec §3, §4): the 24 names in order, every tool annotated in
  # full, every schema closed. A tool that forgot `reads!` would be presented as destructive, and a
  # schema without additionalProperties: false lets a misspelt argument through to a keyword error.
  class CatalogTest < ActionDispatch::IntegrationTest
    include McpClient

    NAMES = %w[
      list_projects get_project create_project update_project
      list_tasks create_task update_task
      list_build_log add_build_log_entry
      list_inventory get_inventory_item create_inventory_item update_inventory_item adjust_inventory
      get_bom add_bom_line update_bom_line
      list_suppliers create_supplier list_locations create_location
      list_folder read_text_file search
    ].freeze
    READS = NAMES.grep(/\A(list_|get_|read_|search)/).freeze
    IDEMPOTENT_WRITES = NAMES.grep(/\Aupdate_/).freeze

    setup { @token = bootstrap_token(email: "mcp-catalog@example.com", device_name: "assistant") }

    test "tools/list is exactly the 24 tools, in order" do
      tools = mcp_rpc(@token, "tools/list").dig("result", "tools")
      assert_equal NAMES, tools.map { |t| t["name"] }
    end

    test "every tool is annotated in full, closed to unknown arguments, and described" do
      tools = mcp_rpc(@token, "tools/list").dig("result", "tools")
      tools.each do |t|
        name = t["name"]
        annotations = t.fetch("annotations") { flunk "#{name} has no annotations" }
        assert_equal %w[destructiveHint idempotentHint openWorldHint readOnlyHint], annotations.keys.sort, name
        assert_equal false, annotations["destructiveHint"], "#{name} must not read as destructive"
        assert_equal false, annotations["openWorldHint"], "#{name} acts on a closed dataset"
        assert_equal READS.include?(name), annotations["readOnlyHint"], name
        assert_equal(READS.include?(name) || IDEMPOTENT_WRITES.include?(name), annotations["idempotentHint"], name)
        assert_equal false, t.dig("inputSchema", "additionalProperties"), "#{name}'s schema must be closed"
        assert_operator t["description"].to_s.length, :>=, 40, "#{name} needs a real description"
      end
    end
  end
end
```

- [ ] **Step 2: The isolation test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  # THE HEADLINE TEST (spec §8, §9): user A's token reaches none of user B's data, by any tool, read
  # or write. Every finder in McpServer::Tool starts from the user; this is what makes that a
  # guard rather than a convention. Mutation-checked by dropping `user.` from one finder.
  class IsolationTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @a = bootstrap_token(email: "mcp-a@example.com", device_name: "assistant")
      bootstrap_token(email: "mcp-b@example.com", device_name: "assistant")
      @b = User.find_by!(email: "mcp-b@example.com")
      @theirs = @b.maker_projects.create!(name: "Theirs")
      project_folder_rows!(@b, @theirs)
      @task = @b.maker_tasks.create!(taskable: @theirs, title: "Their task")
      @item = @b.maker_inventory_items.create!(name: "Their bolts")
      @bom = @theirs.boms.create!(user: @b)
      @line = @bom.lines.create!(user: @b, part_name: "Their part")
      @secret = @b.nodes.create!(node_id: SecureRandom.uuid, name: "Secret", kind: "dir", mtime: 1, size: 0)
      @b.nodes.create!(node_id: SecureRandom.uuid, name: "plans.md", kind: "file", parent_node_id: @secret.node_id, mtime: 1, size: 5)
    end

    test "reads answer nothing of the other user's" do
      assert_equal [], mcp_structured(@a, "list_projects")["projects"]
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "get_project", { slug: "theirs" })
      assert_equal [], mcp_structured(@a, "list_tasks")["tasks"]
      assert_equal "No inventory item with id #{@item.id}.", mcp_refusal(@a, "get_inventory_item", { id: @item.id })
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "get_bom", { project: "theirs" })
      assert_equal [], mcp_structured(@a, "list_folder")["entries"]
      assert_equal "No file or folder at \"Secret\".", mcp_refusal(@a, "list_folder", { path: "Secret" })
      assert_equal "No file or folder at \"Secret/plans.md\".", mcp_refusal(@a, "read_text_file", { path: "Secret/plans.md" })
      out = mcp_structured(@a, "search", { q: "their" })
      assert_equal [ [], [], [], [] ], out.values_at("files", "folders", "projects", "inventory")
    end

    test "writes change nothing of the other user's" do
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "update_project", { slug: "theirs", name: "Mine now" })
      assert_equal "Theirs", @theirs.reload.name
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "create_task", { project: "theirs", title: "x" })
      assert_equal "No task with id #{@task.id}.", mcp_refusal(@a, "update_task", { id: @task.id, status: "done" })
      assert_equal "todo", @task.reload.status
      assert_equal "No inventory item with id #{@item.id}.", mcp_refusal(@a, "adjust_inventory", { id: @item.id, delta: 5 })
      assert_equal 0, @item.reload.quantity_cached
      assert_equal "No BOM line with id #{@line.id}.", mcp_refusal(@a, "update_bom_line", { id: @line.id, quantity: 9 })
      assert_equal 1, @line.reload.quantity
      assert_equal "No project \"theirs\".", mcp_refusal(@a, "add_build_log_entry", { project: "theirs", body: "x" })
      assert_empty @theirs.build_log_entries
    end

    test "a write on your own row cannot point at the other user's rows" do
      mine = User.find_by!(email: "mcp-a@example.com").maker_projects.create!(name: "Mine")
      message = mcp_refusal(@a, "add_bom_line", { project: "mine", inventory_item_id: @item.id })
      assert_match(/Inventory item/i, message)
      assert_empty mine.boms.flat_map(&:lines)
    end
  end
end
```

- [ ] **Step 3: The query budget test**

```ruby
require "test_helper"
require "support/mcp_client"

module Mcp
  # CONSTANCY IN N, NEVER A LITERAL (page_query_budget_test.rb's rule, for the same reason: the
  # counts differ per LIBRARY_BACKEND, and the property that matters is that a tool does not grow
  # with the data it renders).
  class QueryBudgetTest < ActionDispatch::IntegrationTest
    include McpClient

    SMALL = 3
    LARGE = 15

    setup do
      @token = bootstrap_token(email: "mcp-budget@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-budget@example.com")
    end

    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        n += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # Warm once, measure, grow, warm, measure.
    def assert_constant(name, arguments, grow)
      grow.call(SMALL)
      mcp_structured(@token, name, arguments)
      small = count_queries { mcp_structured(@token, name, arguments) }
      grow.call(LARGE - SMALL)
      mcp_structured(@token, name, arguments)
      large = count_queries { mcp_structured(@token, name, arguments) }
      assert_equal small, large, "#{name} issued #{small} queries at the small size and #{large} at the large one"
    end

    test "get_project does not grow with tasks, entries, BOMs or attachments" do
      lamp = @user.maker_projects.create!(name: "Lamp")
      folder = project_folder_rows!(@user, lamp)
      grow = lambda do |n|
        n.times do |i|
          @user.maker_tasks.create!(taskable: lamp, title: "t#{i}")
          lamp.build_log_entries.create!(user: @user, body: "e#{i}", logged_at: Time.current)
          lamp.boms.create!(user: @user, revision: lamp.boms.count + 1).lines.create!(user: @user, part_name: "p#{i}")
          node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "f#{i}.stl", kind: "file", parent_node_id: folder.node_id, mtime: 1, size: 1)
          lamp.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
        end
      end
      assert_constant("get_project", { slug: "lamp" }, grow)
    end

    test "list_projects does not grow with projects" do
      grow = ->(n) { n.times { |i| project_folder_rows!(@user, @user.maker_projects.create!(name: "P#{SecureRandom.hex(3)}")) } }
      assert_constant("list_projects", {}, grow)
    end

    test "list_folder, list_tasks, list_inventory and get_bom do not grow with rows" do
      root = @user.nodes.create!(node_id: SecureRandom.uuid, name: "Stuff", kind: "dir", mtime: 1, size: 0)
      assert_constant("list_folder", { path: "Stuff" }, ->(n) { n.times { |i| @user.nodes.create!(node_id: SecureRandom.uuid, name: "n#{SecureRandom.hex(3)}.txt", kind: "file", parent_node_id: root.node_id, mtime: 1, size: 1) } })
      lamp = @user.maker_projects.create!(name: "Lamp")
      assert_constant("list_tasks", {}, ->(n) { n.times { |i| @user.maker_tasks.create!(taskable: lamp, title: "t#{i}") } })
      loc = @user.maker_locations.create!(name: "Bench")
      assert_constant("list_inventory", {}, ->(n) { n.times { |i| @user.maker_inventory_items.create!(name: "i#{SecureRandom.hex(3)}", location: loc) } })
      bom = lamp.boms.create!(user: @user)
      item = @user.maker_inventory_items.create!(name: "bolt")
      assert_constant("get_bom", { project: "lamp" }, ->(n) { n.times { bom.lines.create!(user: @user, inventory_item: item, quantity: 1) } })
    end
  end
end
```

- [ ] **Step 4: Run the three** → green. Then **mutation-check isolation**: in `app/services/mcp_server/tool.rb` change `user.maker_projects.find_by(slug: slug.to_s)` to `Maker::Project.find_by(slug: slug.to_s)` → `isolation_test` goes red on `get_project` AND `update_project` (report which assertions). Restore. Mutation-check the budget: in `Render.task` change the signature to `def task(t, project: nil)` and `project.is_a?` to `t.taskable.is_a?` → `get_project` budget goes red. Restore.

- [ ] **Step 5: The invariant in CLAUDE.md**

In §14d, after the bullet that begins `**`Current.library_unreachable` IS SET ONLY WHERE…`, add:

```markdown
- **THE MCP DOOR IS TOKEN-AUTHED, STATELESS, AND ITS TOOLS CALL THE MODELS, NEVER v1 OVER HTTP**
  (`McpController`, `app/services/mcp_server/`; spec 2026-11-04). One JSON-RPC message per POST,
  no session, no SSE; a tool is scoped by the user in the server context and every finder starts
  from it (`isolation_test.rb`). The Settings door mints an assistant's device with **no sync
  grant** and shows the token **once, rendered, never through the flash**.
```

Then run `bin/rails test test/docs_hygiene_test.rb`. It is red by the bullet's line count (CLAUDE.md was exactly at `MAX_LINES` = 1,354). Raise `MAX_LINES` in `test/docs_hygiene_test.rb` by exactly that count (5 → `1_359`) and add to the comment above it: `# 2026-11-04: +5 for the MCP-door invariant (§14d).` Re-run → green.

- [ ] **Step 6: `bin/rubocop test/integration/mcp`** → no offenses. Report everything.

---

### Task 11: Close-out (orchestrator)

- [ ] **Step 1:** `git status --porcelain` and `git diff --stat origin/main -- app/ lib/ config/ db/` — every path is one a task named; no stray mutation survived.
- [ ] **Step 2:** Full gates from the worktree:
  ```bash
  export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync
  bin/ci
  ```
  All seven gates green and the three backend legs' RUN counts identical. If `../tinkerex-sync` is missing: `gh repo clone chaim354/tinkerex-sync /Users/charlesschwartz/Desktop/repos/tinkerex-sync` first.
- [ ] **Step 3: Live check.** Start the dev server (`.claude/launch.json`'s entry, or `bin/dev` from the worktree with `RAILS_MAX_THREADS=16`), sign in, Settings → Devices → Connect, copy the command, then from any terminal:
  ```bash
  claude mcp add --transport http tinkerex-dev http://localhost:3000/mcp --header "Authorization: Bearer <token>"
  claude mcp list
  ```
  and in a Claude Code session ask it to call `list_projects` and `read_text_file` on a README. Record the output in the PR body. Remove with `claude mcp remove tinkerex-dev`.
- [ ] **Step 4:** `/finish-branch` (commit anything left, push, open the PR; the PR body states what was verified: the suite on three legs, the live check, the mutation checks).
- [ ] **Step 5:** `bin/log arc --from-pr <n>` as the PR opens (CLAUDE.md §15).
