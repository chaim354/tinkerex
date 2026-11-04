# An MCP server for the maker library — design

**Date:** 2026-11-04. **Status:** approved in conversation; implementation plan follows.

## 1. What this is

Tinkerex gains a [Model Context Protocol](https://modelcontextprotocol.io) server so an AI client
(Claude Code, Claude Desktop, any MCP client) can work in a user's library: read and change
projects, tasks, the build log, inventory and bills of materials, and browse the library's folders
and read its text files. It ships inside the Rails app at `POST /mcp`, authenticated with the same
device token the `v1/maker/*` API accepts, and a user mints a token for it on Settings → Devices.

Three decisions were taken in the design conversation and are not reopened here:

1. **Purpose**: work *in* a library, not operate the server and not drive the `/tools` add-ons.
2. **Hosting**: inside Rails at `/mcp`, not a standalone stdio script.
3. **Scope**: read **and** write across the maker layer, **plus** the library tree (folders and
   text files). No deletes, no file writes, no bytes other than text.

## 2. The approach, and the two rejected

**Chosen: a thin stateless controller over the official SDK, tools on the models.**
`McpController < ActionController::API` includes `V1::Authentication`; each `POST /mcp` builds an
`MCP::Server` (the `mcp` gem, 1.9.0, Apache-2.0; its one dependency `json_schemer` is MIT) with the
tool classes and a server context of `{ user:, device: }`, calls `handle_json` on the raw body and
renders the JSON answer. Every tool is a small `MCP::Tool` subclass calling the models and services
the web layer already uses. No sessions, no SSE, no per-client process memory.

**Rejected: mounting the SDK's `StreamableHTTPTransport` as a Rack endpoint.** It brings sessions
held in one process (broken at `WEB_CONCURRENCY > 1`), an `allowed_hosts` check that 403s every
deployment hostname until listed, and moves auth out of Rails controllers, losing `rescue_from`,
request logs and the demo gate. None of its extra features (SSE streams, server-initiated requests)
serve CRUD tools.

**Rejected: tools that proxy to the v1 JSON API.** Over HTTP that points a synchronous client at
the same Puma pool (CLAUDE.md §14e: 14–24 s stalls, measured). Through an in-process Rack call it
re-enters the middleware stack and authenticates twice. v1's JSON is id-heavy where an assistant
wants names and paths.

## 3. Wiring

| piece | where | what |
|---|---|---|
| gem | `Gemfile` | `gem "mcp", "~> 1.9"` |
| route | `config/routes.rb`, beside `namespace :v1` | `match "mcp", to: "mcp#create", via: :post`; GET → `mcp#show` (405 + JSON hint + `Allow: POST`); DELETE → `mcp#destroy` (204) |
| controller | `app/controllers/mcp_controller.rb` | `< ActionController::API`, `include V1::Authentication`; a body over **1 MiB** answers 413 before parsing; a JSON-RPC notification (the SDK returns nil) answers 202 with no body |
| server | `app/services/mcp_server.rb` | `McpServer.build(user:, device:)` → `MCP::Server.new(name: "tinkerex", version:, instructions:, tools: TOOLS, server_context: { user:, device: })` |
| tool base | `app/services/mcp_server/tool.rb` | `McpServer::Tool < MCP::Tool`: reads `user` from the context, `ok(payload)` / `refuse(message)` response helpers, the exception map of §7, and `reads!` / `writes!` annotation helpers |
| render | `app/services/mcp_server/render.rb` | the ONE place a project, task, entry, item, BOM, line, supplier, location or node is shaped for an LLM |
| paths | `app/services/mcp_server/library_path.rb` | library-relative path ⇄ node (§5) |
| tools | `app/services/mcp_server/tools/{projects,tasks,build_log,inventory,bom,reference,library}.rb` | one module per domain, one class per tool, named with `tool_name` |
| initializer | `config/initializers/mcp.rb` | the SDK's exception reporter → `Rails.error.report(handled: true)`; argument validation on |

**Tool results** are one `text` block holding compact JSON and the same hash as
`structured_content`. **Annotations are always stated in full**, because the SDK's defaults are
`destructiveHint: true` and `openWorldHint: true`: every read tool declares `readOnlyHint: true,
destructiveHint: false, idempotentHint: true, openWorldHint: false`; every write tool declares
`readOnlyHint: false, destructiveHint: false, openWorldHint: false`, with `idempotentHint: true`
on the `update_*` tools and `false` on the `create_*`/`add_*`/`adjust_*` ones. `openWorldHint`
is false everywhere: every tool acts on this user's own closed dataset. The server's `instructions` string explains identifiers (below), that
paths are library-relative, that `list_*` results are capped and flag `truncated`, and that
writes are real.

**Identifiers**: a project by its **slug**. Tasks, inventory items, BOMs, BOM lines, suppliers and
locations by their numeric **id**, which every listing returns. Files and folders by
**library-relative path** (`Projects/lamp/README.md`), returned beside the node id.

## 4. The tool catalog — 24 tools, no deletes

**Projects**
- `list_projects(status?, q?)` — slug, name, status, kind, folder path, open task count,
  updated_at. Ordered by updated_at desc, **capped at 100**, `truncated: true` past it.
- `get_project(slug)` — the row plus description, visibility, folder path, tasks (open first),
  the **last 20** build-log entries as plain text (`body.to_plain_text`), BOMs with line counts,
  attached files with paths.
- `create_project(name, description?, status?, kind?)` — `status` ∈ `Maker::Project::STATUSES`,
  `kind` ∈ `KINDS`; the slug is derived by the model (`ensure_slug`). Then mints the project's
  library folder through `Maker::Project#ensure_library_folder!`, best-effort as
  `ProjectsController#create` does: a `FileLayer::FetchError` or `UnsupportedOperation` there is
  answered as `folder: null` plus a `note` naming it, and the project is still created.
- `update_project(slug, name?, description?, status?, kind?)` — one `save!`: a `status` of
  `"archived"` stamps `archived_at` (kept if already set) exactly as `Maker::Project#archive!`
  does, and any other `status` clears it as `#unarchive!` does. No delete exists.

**Tasks**
- `list_tasks(project?, status?)` — all the user's tasks or one project's; `status` ∈
  `Maker::Task::STATUSES`. Open first, then by position.
- `create_task(project, title, notes?, status?)` — taskable is the project.
- `update_task(id, title?, notes?, status?)` — `completed_at` follows `status` exactly as
  `V1::Maker::TasksController#update` does.

**Build log**
- `list_build_log(project, limit?)` — newest first, `limit` default 20, max 100.
- `add_build_log_entry(project, body, entry_type?, logged_at?)` — `entry_type` ∈
  `Maker::BuildLogEntry::ENTRY_TYPES`; `logged_at` ISO-8601, default now. Body is plain text; it
  passes through `Maker::TextOnlyRichText` like every other door.

**Inventory**
- `list_inventory(q?, low_stock?, location_id?)` — id, name, part_number, category, quantity, unit,
  min_quantity, location name, supplier name, low_stock flag. Capped at 200.
- `get_inventory_item(id)` — the row plus notes, unit_cost, and the **last 20** transactions.
- `create_inventory_item(name, unit?, quantity?, min_quantity?, part_number?, category?,
  unit_cost?, location_id?, supplier_id?, notes?)` — `unit` ∈ `Maker::InventoryItem::UNITS`. A
  non-zero `quantity` is applied through `Maker::InventoryTransaction.apply!` with reason
  `"initial"` so the ledger stays the one source of the balance.
- `update_inventory_item(id, ...)` — the same fields minus `quantity`.
- `adjust_inventory(id, delta, reason?, note?, project?)` — `Maker::InventoryTransaction.apply!`,
  exactly the v1 `adjust` call; `project` is a slug resolved to `project_id`.

**Bill of materials**
- `get_bom(project, bom_id?)` — the project's BOMs listed; the chosen one (by id, else the
  first) with its lines: id, reference, quantity, unit, target kind, the item or part name,
  supplier, notes, and `Maker::BomRollup`'s `short` list (on hand vs needed) and
  `estimated_cost`.
- `add_bom_line(project, bom_id?, inventory_item_id?, part_name?, quantity?, unit?, reference?,
  supplier_id?, notes?)` — exactly one of `inventory_item_id` / `part_name`, enforced by the
  model. A project with no BOM gets one created (name "BOM", revision 1) on the first call.
- `update_bom_line(id, quantity?, unit?, reference?, notes?, part_name?, inventory_item_id?)`.

**Reference data**
- `list_suppliers`, `create_supplier(name, url?, notes?)`.
- `list_locations` (id, name, parent name), `create_location(name, parent_id?, description?)`.

**Library**
- `list_folder(path?)` — the live, visible children of a folder (the root when omitted):
  name, kind, size, modified_at, node_id, path, and `text: true` where `read_text_file` can read
  it. Same filter as the Files page (`Node.present.visible_entries(false)`), so dot-files, the
  `.git` marker and build output are hidden. Folders first, then files, by name.
- `read_text_file(path)` — bytes through `FileLayer.current.read`, **capped at
  `Maker::Readme::READ_LIMIT` (256 KB)** by the catalog's size before the read and by the bytes
  after it, UTF-8 forced and scrubbed. A file `Maker::FileAttachment.text?` says no to is refused
  naming its kind.
- `search(q)` — files, folders, projects and inventory items in one call, **five per kind**,
  the `SearchController` idiom (`LOWER(col) LIKE ? ESCAPE '\'`, `q` capped at 80).

**Deliberately absent**: Items, collections and tags (the catalog layer nobody uses), every
delete, file writes and uploads, previews, releases, MCP resources and prompts, OAuth.

## 5. Library paths

`McpServer::LibraryPath`:
- `resolve(user, path)` → a live `Node` or nil. Splits on `/`, drops empty segments, **refuses**
  `.` and `..` segments (nil, never normalised — §14a's `key_for` rule), walks from the root one
  query per segment through `user.nodes.present.where(parent_node_id:, name:)`, **at most 32
  segments**. `""` and `"/"` are the root.
- `path_of(tree, node)` → the path string, from `Maker::LibraryTree#path_for(parent)` joined with
  the node's name; nil when the chain is broken (a tombstoned ancestor), which the tools render
  as `path: null` rather than guessing.
- One `Maker::LibraryTree` per tool call, so paths for N rows cost one pluck.

## 6. The token door

- **Form on Settings → Devices**: "Connect an AI assistant", one text field `device[name]`
  defaulting to `AI assistant`, `data-turbo="false"`, posting to `POST /settings/devices`
  (`Settings::DevicesController#create`, session-authed).
- **Mints** `Device.register!(user:, name:)` with **no sync grant**: an MCP client never syncs,
  and a dead sync server must not block connecting an assistant. The row lists beside desktop
  apps with the same idle clock, expiry and Sign out, and a password change revokes it.
- **Shown once**: the POST **renders** `settings/devices/connected` (status 200, never a
  redirect) with the token, the server URL from `request.base_url`, a ready
  `claude mcp add --transport http tinkerex <url>/mcp --header "Authorization: Bearer <token>"`
  line, and a generic JSON config snippet, each with the existing `copy` Stimulus controller.
  The plaintext never touches the flash, the session or the log.
- **Demo**: `Tinkerex::Demo.demo?(current_user)` is refused (redirect to the Devices page with an
  alert, no row), matching both v1 doors.
- **Copy**: the page's lead sentence becomes "The desktop apps and assistants connected to your
  account"; the sync note stays conditional on `syncable?`. The connected page says which clients
  the token works with (Claude Code, Claude Desktop via a local config, any client that can send
  a header) and that claude.ai's hosted connectors need OAuth, which this server does not offer.
- Design-system rules apply (docs/invariants/design-system.md): no accent on this page except
  the one primary action (the Connect submit is a quiet `.btn`), notices verb-first with a full
  stop, any new component selector defined in `components.css`.

## 7. Errors, as the client sees them

| condition | answer |
|---|---|
| no / unknown / expired token | 401 `{ "error": "unauthorized" }` from the controller, before parsing |
| body over 1 MiB | 413, before parsing |
| malformed JSON, unknown method | the SDK's JSON-RPC error |
| `McpServer::NotFound` (a slug, id or path that resolves to nothing for this user) | tool result, `isError: true`, "No project `lamp`." / "No file at `Projects/x`." |
| `ActiveRecord::RecordInvalid` | `isError: true`, the validation messages |
| `FileLayer::NotFound` | `isError: true`, "No file at `<path>`." |
| `FileLayer::FetchError` | `isError: true`, "The library is unreachable right now. Try again in a moment." (the web's 503) |
| `FileLayer::UnsupportedOperation` | `isError: true`, the adapter's message (the web's 422) |
| anything else | JSON-RPC internal error with no detail; reported to `Rails.error` |

Nothing rescues `NotImplementedError` (§14a). A tool never raises an `ArgumentError` for client
input: the SDK validates arguments against each tool's `input_schema` first.

## 8. Tenancy and security

- Every query starts from `current_user` (`current_user.maker_projects`, `current_user.nodes`),
  never a bare model. A foreign slug, id or path is a not-found, never a disclosure.
- The endpoint is Bearer-only: no session, no CSRF, no cookies read. `McpController` descends
  from `ActionController::API`, so the architecture guard's default-deny rule for
  `ApplicationController` descendants does not apply; the guard that DOES reach it is "no
  controller rescue_froms a bare ArgumentError" (`architecture_invariants_test.rb`, which scans
  every `ActionController::API` descendant under `app/controllers/`), and the controller
  declares no `rescue_from` at all — the error map of §7 lives in the tool base class.
- The demo account can never hold a token: the Settings door refuses it and the v1 doors already
  do.
- No new environment variable. `docs/INSTALL.md` is untouched.

## 9. Testing

`test/integration/mcp/`:
- `protocol_test.rb` — `initialize` answers the server name and tool capability;
  `notifications/initialized` answers 202 empty; `tools/list` returns exactly the 24 names and
  every write tool carries its annotations; 401 without a token and with an expired one; 405 on
  GET with `Allow: POST`; 413 over the cap; a malformed body is a JSON-RPC error, not a 500.
- `isolation_test.rb` — **the headline test**: user A's token cannot list, get, update or adjust
  user B's project, task, item, BOM line or file. Mutation-checked by dropping `current_user.`
  from one tool and watching it go red (§15).
- one test file per tools module (`projects_tools_test.rb` …) driving `tools/call` through the
  real models and asserting the structured content.
- `library_tools_test.rb` — on `use_fresh_share_library!` with `create_node!` plus real bytes,
  the same recipe `markdown_file_page_test.rb` uses, so the three backend legs run identical
  RUNS. A `replacing` stub on `read` raising `FetchError` pins the unreachable wording;
  `..` in a path is refused; a 300 KB file is refused before the read; a `.stl` is refused as
  non-text.
- `query_budget_test.rb` — `get_project` and `list_folder` issue a constant number of queries
  between 3 and 15 rows, in `page_query_budget_test.rb`'s style (constancy, never a literal).
- `test/integration/web/settings_devices_connect_test.rb` — the form renders `device[name]`
  (assert the rendered field name, §14d); the POST mints a row with no `sync_device_id`, renders
  the token once, and the token then authenticates `/mcp`; the demo is refused with no row; the
  Devices list shows the new row and Sign out revokes it (the token then 401s).
- Live check in the plan: `bin/dev`, mint a token on the page, `claude mcp add`, call
  `list_projects` and `read_text_file` from Claude Code.

## 10. Docs and invariants

- `docs/mcp.md`: setup for Claude Code (the `claude mcp add` line), Claude Desktop (a local
  `mcp-remote`-style config with the header), the tool list with one line each, the limits, and
  the OAuth limitation.
- CLAUDE.md §14d, one bullet: the MCP endpoint is token-authed, stateless, with tools on the
  models and never on v1 over HTTP; the Settings door mints a device with no sync grant.
- The arc is filed with `bin/log arc --from-pr` as the PR opens (§15).

## 11. Follow-ups (not in this arc)

- OAuth 2.1 for claude.ai's hosted connectors.
- MCP resources for files (`tinkerex://…` URIs) once a client wants them.
- Items, collections, tags, releases, deletes, file writes.
