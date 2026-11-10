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

The assistant appears on the Devices page like any other connected app, with the same idle expiry
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
