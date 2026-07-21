# Projects — web UI (the maker hub in the browser)

**Date:** 2026-07-21
**Status:** approved (design)
**Scope:** a server-rendered web UI for **`Maker::Project`** and the things it owns —
build log, tasks, attached design files — plus **cover thumbnails** and an
**attach-from-Files** action. Session-auth web layer only (`app/controllers/*`,
`app/views/*`, `application.css`, minimal Stimulus). **No** BOM UI, **no** changes to
sync / the changelog / conflicts / locks / the mounts (CLAUDE.md §10 tripwire). Reads
file metadata through the `FileLayer` port; uploads reuse the existing capability-aware
web upload flow. No new server models or migrations.

## Problem

The maker product is API-complete but has almost no web surface. Models **and** a tested
`/v1/maker/*` JSON API exist for projects, tasks, build-log entries, file attachments,
BOMs, inventory, suppliers, locations, tags, collections — with ~30 integration tests.
The **desktop (Tauri) app** surfaces projects and inventory. But the **hosted web app**
renders only `files`, `tools`, `trash`, and `users` (auth). For a product whose business
model is hosting, the web experience is currently "a file browser with previews."

Projects is the natural first web surface: a `Project` already `has_many`
build_log_entries, tasks, file_attachments (polymorphic), and boms — so one Projects UI
pulls in most of the maker layer as a coherent vertical, and it visibly ties together the
design files + fresh preview thumbnails that are the product's crown jewel.

## Decisions (from brainstorming)

- **Scope this session:** the **hub minus BOM**. Project list + create/edit → detail page
  with **build log**, **attached design files**, and **tasks**. The BOM editor (three
  target types, revisions, roll-up against live inventory) is the most complex piece and
  gets its **own follow-up spec**.
- **Included features:** **cover thumbnails** (auto-derived) and **attach-from-Files** (an
  "Attach to project" action in the file browser).
- **Backlogged (near-free later, not discarded):** progress-bar-from-tasks, markdown
  description rendering, milestone-styled log entries, and the **public shareable project
  page** (the big differentiator — its own spec).

## Model facts this design relies on (already in the codebase)

- `Maker::Project` — `name`, `slug` (unique per user), `description` (text), `status`
  (`planning|active|paused|done|archived`), `archived_at`; `#archive!`; `#ensure_slug`.
- `Maker::BuildLogEntry` — `body` (required), `entry_type` (`note|milestone`),
  `logged_at`; **`has_many :file_attachments, as: :attachable`** (so photos are
  model-supported).
- `Maker::Task` — `title`, `status` (`todo|doing|done`), `notes`, `position`,
  `completed_at`; polymorphic `taskable` (`Maker::Project|Maker::Item`); `#complete!`.
- `Maker::FileAttachment` — `node_id` (required), `role`
  (`model|instructions|image|source_archive|gcode|other`), `label`, `position`,
  `version_id` (optional pin); polymorphic `attachable` (Project **or** BuildLogEntry).
- `FileLayer.current.stat_all(user, node_ids:)` → Hash keyed by `node_id`; **a missing
  node is an absent key, not a raise** (CLAUDE.md §3) — exactly what a tile grid needs.

## Approach

### 1. Architecture — server-rendered Hotwire, session auth, models directly

New web controllers under the session-authenticated top-level namespace (like
`FilesController`/`Tools::*`), querying `Maker::*` scoped to `current_user`. Turbo Frames
/ Streams for inline add/edit (task row, log entry) without full reloads; the existing
`uploader` Stimulus controller reused for upload-and-attach. Plain ERB + partials +
`application.css`.

Rejected alternatives: a **JS SPA against `/v1/maker`** would have to bridge
session→device-token (that API is `Bearer`-only via the `Authentication` concern) —
duplicate auth, inconsistent with the web app. **Reusing the desktop JS** won't port (it
targets Tauri `invoke`, not HTTP+session).

Because the web UI uses the models directly, it is **not** limited by which routes the
JSON API exposes — e.g. `/v1/maker` has no "attach a file to a build-log entry" route, but
the web controller creates that polymorphic attachment directly.

### 2. Surfaces & routes

```ruby
resources :projects do                        # index, new, create, show, edit, update, destroy
  resources :build_log_entries, only: %i[create destroy], shallow: true
  resources :tasks,             only: %i[create update destroy], shallow: true   # + member reorder
  resources :attachments,       only: %i[create destroy], shallow: true
end
```

- **`/projects`** — project cards grouped by status (`planning|active|paused|done`;
  `archived` collapsed/hidden by default), each card = cover thumbnail + name + status
  chip. "New project" opens `_form`.
- **`/projects/:slug`** — detail; slug lookups are **user-scoped** (`current_user`;
  another user's slug → 404). Three panels (below).
- **`DELETE /projects/:slug`** maps to **`#archive!`** (soft; sets `status:"archived"`).
  Hard delete (which cascades `dependent: :destroy` over the join rows — never the library
  files) is a secondary affordance, deferred.
- **Nav:** add **"Projects"** to the topbar in `layouts/application.html.erb`, between
  Files and Tools.
- **Friendly slug URLs** (`/projects/desk-lamp`) over numeric ids (decided default).

### 3. Project detail — Attached files panel

A grid of **thumbnail tiles**, mirroring `files/_grid`. Each tile: preview thumbnail +
file name + a `role` badge + a pin indicator when `version_id` is set; the tile links to
`files#show` for that node.

- **Attach existing** (decided default for v1): a name-**search box + recent files** list
  (not a full embedded tree browser). Picking a node creates a `FileAttachment`. *Plan
  integration point:* the current search route (`/v1/search`) is device-token-authed, so
  this needs a **small session-auth search** — a new web action over `FileLayer.current`
  (name match, user-scoped) or a reuse of the Files listing. "Recent files" can come from
  the user's recent nodes / prior attachments.
- **Upload & attach:** reuses the existing capability-aware web upload flow
  (`files#create`, or `begin_upload`+`finalize` in chunk mode); on success, create the
  attachment. Destination = the upload flow's existing default (current/root folder). A
  tidy per-project **`Projects/<slug>/`** folder is a **nice-to-have that depends on a
  session-auth folder-create path** (web `mkdir` is currently device-token-only) — treat
  it as optional in the plan, not a blocker. **No new sync code** either way — just
  orchestration of existing machinery.
- **Role auto-inferred** from extension on attach: `.stl/.3mf/.obj/.step→model`,
  images→`image`, `.pdf→instructions`, `.gcode/.gco→gcode`, else `other`. User can change
  it.
- **Detach** destroys the `FileAttachment` **reference only** — it never deletes or
  trashes the library file. Copy in the UI must make this unmistakable.

### 4. Project detail — Build log panel

A reverse-chronological timeline (`order(:logged_at)` desc for display). Each entry: the
`body` text + any inline **photos** (its `file_attachments` with `role:"image"`, rendered
as thumbnails).

- **Add entry:** body (required) + optional photo(s). Photos follow the same
  attach-existing / upload-&-attach path as §3, attached to the **entry** (not the
  project). Turbo Stream prepends the new entry.
- **Delete entry:** removes it and its attachment rows (`dependent: :destroy`), never the
  library files.
- `entry_type` is stored (`note` default). **Milestone styling is backlogged**, so v1
  renders all entries uniformly; the column is populated so the later feature is purely
  presentational.

### 5. Project detail — Tasks panel

An **ordered checklist** grouped by `status` (`todo|doing|done`), ordered by `position`.

- Add task (title), rename, edit `notes`, change status, **reorder** (updates
  `position`), delete. `#complete!` stamps `completed_at`.
- Status change and reorder use Turbo Streams for a snappy feel; the panel degrades to
  plain form posts with no JS. A full drag-kanban is **not** in scope — grouped list with
  status controls is enough for v1.

### 6. Cover thumbnails (feature)

`Project#cover_node_id` = first attachment with `role:"image"` → else first `role:"model"`
→ else first attachment (by `position`) → else `nil`. Rendered through the **existing
preview/thumbnail path** (`Maker::Previews::*` + the files thumbnails route). No schema
change. A project with no attachments (or whose cover node is missing) shows a neutral
placeholder card.

### 7. Attach-from-Files (feature)

An **"Attach to project…"** control on `files#show` (and the list/grid row menu). It opens
a Turbo-frame picker of the current user's projects; choosing one POSTs to
`Projects::AttachmentsController#create` with `project_id` + `node_id`, role inferred as in
§3. This lets a file be sent to a project from where you're already browsing, without
leaving the file browser.

### 8. Data flow & the file-layer boundary

Attachments and build-log photos are **references** (`node_id` + optional `version_id`),
never copies. To render a tile grid the controller **bulk-reads** metadata via
**`FileLayer.current.stat_all(current_user, node_ids: [...])`** (one call, not an N+1 of
`stat`), then resolves thumbnails through the existing preview path.

- A **missing/trashed** node returns as an **absent key** → its tile degrades to a "file
  unavailable" placeholder. Never a broken image, never a 500.
- An **unmounted share** backend (`FileLayer::FetchError`) degrades the same way (the files
  browser already handles this; reuse the pattern).

**Guardrail (CLAUDE.md §10):** this work stays on the maker side plus the FileLayer port's
public **read** surface (`stat_all`) and the **existing** upload flow. It must not import
or call `Sync::*`, the changelog, conflicts, locks, or the mounts. If a task here appears
to need the sync layer, that is the signal to stop and reconsider the boundary.

### 9. Error handling

- **Attach** verifies the node exists and is owned via `stat_all` before creating the
  reference; a missing/foreign node → flash error, no attachment.
- Model validation failures re-render the form with errors (matching files/tools).
- Everything is **`current_user`-scoped**; another user's project, task, entry, or node →
  **404**, never a cross-tenant leak (mirrors the isolation tests already covering
  `/v1/maker`).

### 10. Testing

Web integration tests (session auth) mirroring `test/integration/web/*`:

- projects index (status grouping) + show; create / edit / archive.
- build-log add-with-photo and delete; task add / complete / reorder / delete.
- attach existing, upload-&-attach, detach (asserting the **library file survives** a
  detach), and attach-from-Files.
- cover-thumbnail derivation (image → model → first → placeholder).
- **tenant isolation** (no cross-user project/node access) and **graceful degrade** when an
  attached node is missing or the backend is unmounted.

Runs on **chunk + share** backends (the attachment/thumbnail read path crosses the port),
matching the existing dual-backend CI legs.

## Out of scope (→ backlog, not trash)

BOM editor (own spec); progress-bar-from-tasks; markdown description rendering;
milestone-styled log entries; public shareable project page (own spec); standalone
inventory / supplier / location management UI (not needed for this slice); hard-delete UI;
drag-kanban tasks.

## Open defaults (flagged; flip on request)

- Friendly **slug URLs** for projects (vs numeric ids).
- Attach "pick existing" via **search box + recent files** (vs a full embedded tree
  browser) — backed by a small session-auth search (§3).
- Uploaded project files use the upload flow's default destination; a per-project
  **`Projects/<slug>/`** folder is optional, gated on a session-auth `mkdir` path (§3).
