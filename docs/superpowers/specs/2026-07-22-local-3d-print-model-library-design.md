# Local 3D-Print Model Library — Design

**Date:** 2026-07-22
**Status:** Approved (brainstorm), ready for implementation plan
**Scope:** One spec / one multi-task plan.

---

## 1. The use case

A maker finds a model on Printables (or MakerWorld / Thingiverse / their own work) and
wants it in their library as one organized, printable thing:

1. On the source site they download the **model files** — usually a single **`.zip`** when
   there are several — plus the **instructions PDF** and the **cover image** where the
   creator provides them.
2. They drop the zip into the app. The browser unpacks it, classifies the contents, and
   creates a **Model**: a catalog entry with a cover, metadata, its files, and print
   tracking.
3. They browse their model library, filter by print status or tag, open a model to read
   the instructions and download the files, and log prints against it over time.

The headline interaction is **"select the zip, click Create"** — the browser does the
unpacking and classification; metadata that can't come from the files is filled in later
on the model page.

## 2. Why this is a new concept (not a Project, not just files)

- **Not a Project.** `Maker::Project` is a build (hardware + firmware + software, with
  tasks, a BOM, and a build log) with statuses `planning/active/paused/done/archived`. A
  downloaded model is lighter and has different metadata (source URL, designer, license)
  and a different status vocabulary (`want_to_print/printed/failed`). A model may later be
  *referenced by* a project without dragging Project's machinery into the catalog.
- **Not just files.** Catalog + print-status need structured, queryable metadata a plain
  folder can't hold.

The files themselves still live in the ordinary file library, at `Models/<slug>/`, so they
sync/preview/back up like everything else. **The Models section is a curated view over
existing library nodes.** Nothing in the file/sync layer changes — **§10 stays honest.**

## 3. Data model

Two new tables. Everything else is reused.

### `Maker::Model` — `maker_models`

| column | type | notes |
|---|---|---|
| `user_id` | int, not null, indexed | tenant scoping (all maker models are user-scoped) |
| `title` | string, not null | |
| `slug` | string, not null | unique per user; `to_param`; friendly `/models/<slug>` URLs |
| `source_url` | string, null | attribution link (Printables/etc.) |
| `designer` | string, null | free text |
| `license` | string, null | free text (e.g. "CC BY-NC") |
| `print_status` | string, not null, default `"want_to_print"` | `want_to_print` / `printed` / `failed` |
| `notes` | text, null | markdown, rendered with the existing `render_note` helper |
| `folder_node_id` | string, null | the `Models/<slug>/` dir node; (re)ensured idempotently |
| `cover_node_id` | string, null | explicit cover override; when nil, cover is derived (see §6) |
| timestamps | | |

Indexes: `[user_id, slug]` unique, `[user_id, print_status]`.

Associations / behavior:
- `belongs_to :user`
- `has_many :file_attachments, as: :attachable, dependent: :destroy` — **reuses the
  existing polymorphic `Maker::FileAttachment`**, whose `ROLES`
  (`model/instructions/image/source_archive/gcode/other`) and `ROLE_BY_EXT` already fit
  this use case exactly.
- `has_many :taggings, as: :taggable, dependent: :destroy` + `has_many :tags, through:` —
  **reuses the existing polymorphic `Maker::Tagging`** (zero schema change).
- `has_many :print_runs, dependent: :destroy`
- `PRINT_STATUSES = %w[want_to_print printed failed]`; validate inclusion.
- `validates :title`, `:slug` (presence + uniqueness scoped to user); `before_validation`
  slug generation — **mirrors `Maker::Project#ensure_slug`**.
- `to_param = slug`.
- `ensure_library_folder!(acting_user)` → find-or-create `Models/<slug>/` via
  `Maker::LibraryFolder.ensure_path!(user, ["Models", slug])` — **mirrors
  `Maker::Project#ensure_library_folder!`** (idempotent; re-creates if the node was
  deleted in the Files browser).
- `cover` resolution helper — see §6.

### `Maker::PrintRun` — `maker_print_runs`

| column | type | notes |
|---|---|---|
| `user_id` | int, not null, indexed | |
| `model_id` | int, not null, indexed | `belongs_to :model` (`Maker::Model`) |
| `printed_on` | date, not null, default today | |
| `printer` | string, null | free text (with a reuse datalist in the UI) |
| `material` | string, null | free text (e.g. "PLA — Prusament Galaxy Black") |
| `outcome` | string, not null | `success` / `failed` |
| `duration_hours` | decimal, null | optional |
| `filament_grams` | integer, null | optional |
| `notes` | text, null | |
| timestamps | | |

Behavior:
- `OUTCOMES = %w[success failed]`; validate inclusion.
- `after_save` and `after_destroy` recompute the parent model's `print_status` from the
  **most recent** print run (latest `printed_on`, tie-break by `id`): `success` ⇒
  `printed`, `failed` ⇒ `failed`. **If no runs remain, the status is left untouched** (it
  was set manually or defaulted to `want_to_print` — the recompute never resets it). The
  pill stays **manually editable**, so this is a convenience default, not a lock. Pin the
  "latest run wins" rule and the "untouched when empty" rule in tests.

## 4. Import mechanics (§15-honest, all three backends)

A new **`importer` Stimulus controller** orchestrates the flow entirely from the existing,
proven upload primitives. **No new write path, nothing server-side unpacks bytes in chunk
mode, nothing reaches into the sync engine.**

1. **User selects the `.zip`** (plus any loose image/PDF that weren't bundled).
2. **Browser unzips** it with **JSZip** (vendored via importmap — no CDN) into a list of
   `{ path, blob }`, preserving internal directory paths.
3. **Auto-classify** each entry by extension using `Maker::FileAttachment.role_for` rules
   mirrored client-side: `.stl/.3mf/.obj/.step/.stp` → `model`; raster images → `image`;
   `.pdf` → `instructions`; else `other`. Pick the first image as the cover (user can
   override before Create). Auto-fill the title from the zip's base name.
4. **`POST /models`** with the title, optional source URL, and the manifest of relative
   file paths. The server creates the `Maker::Model`, ensures `Models/<slug>/` **and every
   internal subfolder** (`LibraryFolder.ensure_path!` per unique directory), and returns
   `{ model_slug, folder_map: { "<relpath>" => node_id }, port_writable }`.
5. **Upload each file** into its mapped folder node, reusing the existing per-backend flow:
   - **chunk** (`port_writable: false`): the two-phase presigned flow
     (`/files/begin_upload` → PUT to storage → `/files/finalize_upload`) — **bytes go
     browser → storage, §15 intact.** The `uploader` controller's logic is refactored into
     a reusable helper the importer calls per file.
   - **share / s3** (`port_writable: true`): one multipart `POST /files` per file with
     `parent_node_id` = the mapped folder (the same `FileLayer.current.write` door
     `FilesController#create` and `Projects::UploadsController` use).
6. **Attach** each uploaded node: `POST /models/:slug/attachments { node_id, role }` (or a
   batch attach) → `model.file_attachments.create!(role:)`, exactly as
   `Projects::UploadsController` does. Set `cover_node_id` from the chosen cover.
7. **Redirect** to the model detail page.

Notes:
- Creating the Model before the uploads finish means an interrupted import leaves a
  partial model; that is acceptable and recoverable (delete + re-import). Simpler and more
  robust than staging.
- The importer surfaces per-file progress and a final "Create" that is disabled until the
  unzip+classify step completes.
- **No auto-fetch from Printables** (ToS). The user supplies the files.

## 5. UI surfaces

All server-rendered Hotwire on the `Maker::Model` records directly (session-auth web UI,
**not** the device-token v1 API) — matching the existing Projects/Files web UI.

- **`/models` (index)** — new top-level nav item next to Files / Projects / Tools
  (`app/views/layouts/application.html.erb`). A grid of cover-image cards (title + status
  pill), a search box (title), status filter (All / Want to print / Printed / Failed), a
  tag filter, and a sort control (Recent / Title / Status). An "Import model" button. Empty
  state. Grid only for v1 (list view is out of scope).
- **Import** (`/models/new` → the `importer` controller) — one smart dropzone, auto-classify
  summary, auto-filled title, optional source URL, Create. §4.
- **Model detail** (`/models/:slug`) — cover + metadata (designer, license, source link,
  tags, added date) on the left; files grouped by role on the right: **Model files** (each
  links to the existing `/files/:node_id` page, which already previews STL/3MF and offers
  download), **Instructions** (inline PDF via the existing viewer), **Images** gallery.
  Header: title, editable status pill, Edit / Open-in-Files / Delete. Notes section
  (reusing `render_note`). Below: the **print log** — a "Log a print" form and the history
  list. Editing metadata + tags happens here (inline or an `/models/:slug/edit` form).
- **Print log** — `POST /models/:slug/print_runs` (create), `DELETE /print_runs/:id`
  (destroy). Free-text printer/material with a `<datalist>` of the user's previously-used
  values for one-tap reuse.

## 6. Cover image resolution

`Maker::Model#cover` returns what the card/detail should render, in order:
1. `cover_node_id` if set and it points at a live image attachment → serve its blob
   (`/files/:node_id/blob`, inline — the existing raster allowlist covers it).
2. else the first `image`-role attachment → its blob.
3. else the first `model`-role attachment → its **server-rendered 3D thumbnail** via the
   existing `Maker::Previews` system (the STL/3MF renderer already in place).
4. else a generic placeholder.

So a model **always** has a usable cover, even from "just the zip" with no photo. Card grids
reuse the existing thumbnail poll-until-ready mechanism where the cover is a rendered
thumbnail.

## 7. Reused vs. new

**Reused (no change):** `FileAttachment` (roles), `Tagging`/`Tag` (polymorphic),
`LibraryFolder.ensure_path!`, `FileLayer` port + capabilities (`port_writable`), the
two-phase + multipart upload paths, `Maker::Previews` (cover fallback + file previews),
`render_note`, the `/files/:node_id` file view.

**New:** `maker_models` + `maker_print_runs` migrations and models; `ModelsController`,
`Models::AttachmentsController` (or a batch attach action), `Models::PrintRunsController`;
the `importer` Stimulus controller + a refactor of `uploader` into a reusable per-file
upload helper; vendored **JSZip** pin; the index/import/detail/edit views + a `Models` nav
link.

## 8. Out of scope (clean follow-ons, deliberately excluded)

- Paste-a-URL auto-fetch from Printables (ToS gray area — rejected in brainstorm).
- Managed **Printers** list; linking print `material` to a `Maker::InventoryItem` filament
  roll with stock deduction.
- **Collections** of models; a **list** view; a "recently printed" shelf.
- A UI to re-assign a file's role after import (fix by re-import or Files browser for v1).
- Keeping the original `.zip` as a `source_archive` attachment (we unpack and discard it;
  revisit if re-download-the-bundle is wanted).

## 9. Invariants honored

- **§10** — no touching sync/changelog/conflicts/locks/mounts. Models is a view over
  existing nodes; folders/writes go through the same `LibraryFolder` + `FileLayer` +
  two-phase doors the web UI already uses.
- **§15** — chunk-mode bytes never flow through Rails (browser unzips, then the two-phase
  presigned flow uploads each file). Share/s3 stream through Rails exactly as their
  existing `write` path already does (the deliberate, scoped departure — a mounted dir /
  bucket write).
- **Tenant = user** — every query scoped to `current_user`.

## 10. Testing

- **Model specs:** `Maker::Model` (slug, validations, `ensure_library_folder!`,
  `cover` resolution order), `Maker::PrintRun` (validations, `after_save`/`after_destroy`
  status recompute — pin "latest run wins" and "untouched when no runs remain").
- **Import:** a service/controller test that drives create → folder-map (including a nested
  subfolder) → attachments-with-roles → cover, asserted on **both** `LIBRARY_BACKEND` legs
  (default chunk + `LIBRARY_BACKEND=share`), matching the existing CI split. Client-side
  unzip/classify logic covered by a small JS unit or a system test with a real zip fixture.
- **Controllers/system:** import happy path, library filters (status/tag/search/sort),
  print-log create/destroy + auto-status, delete-model (cascades attachments + print runs;
  does it delete the files? — v1: **no**, deleting a Model leaves the library files intact,
  same as removing a Project; state this in a test).
- Suite stays green on all three `LIBRARY_BACKEND` legs (`chunk`/`share`/`s3`) as the file
  layer requires.

## 11. Build order (for the plan)

1. Migrations + `Maker::Model` + `Maker::PrintRun` (+ model specs).
2. `ModelsController` index/show/new/edit/update/destroy + views + nav link (no import yet
   — seed a model in a test to render).
3. Server import endpoint (`POST /models` create-with-folder-map) + attach endpoint.
4. Vendor JSZip; refactor `uploader` into a reusable helper; build the `importer` Stimulus
   controller; wire the import form.
5. Cover resolution + card grid + filters/search/sort.
6. Print log (controller + form + history + auto-status).
7. End-to-end pass on both backend legs; polish (empty states, flash messages, datalist).
