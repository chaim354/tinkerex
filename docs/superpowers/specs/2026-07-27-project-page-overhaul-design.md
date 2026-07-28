# Design: project page overhaul — rich text, sheets, typed file groups, no status pipeline

**Date:** 2026-07-27 · **Status:** DESIGN (approved, no code yet)

> **One-liner:** four changes to the project side of the web UI — put **Lexxy** (Basecamp's
> Action Text editor) on build-log entries and file notes, add a **spreadsheet** (`Maker::Sheet`)
> per project, **group a project's attached files by type**, and **hide the status pipeline**
> from the web while leaving the column and the v1 API untouched.

---

## 1. Why

The project page (`/projects/:slug`) is the maker layer's hub: a Files panel, a Build log, and
Tasks. Three gaps and one piece of clutter:

- **The build log is a 2-row plain textarea.** It is the main writing surface on a project —
  what you did, what broke, what to try next — and it cannot do a list, a heading, or a code
  block. File notes have markdown, but you have to *know* markdown and you can't see it until
  you save.
- **There is nowhere to put a table.** Cut lists, cost math, measurements, print-setting
  matrices, test results. Today that lives in a file outside the app or not at all.
- **The Files panel is one flat grid.** A project with 30 attachments mixes STLs, photos, PDFs
  and G-code with no structure beyond a small per-tile role badge.
- **The status pipeline is clutter.** `planning → active → paused → done → archived` is
  five-state ceremony on top of what is really a binary: am I still working on this, or is it
  put away.

None of this touches the FileLayer port, the sync engine, the changelog, conflicts, locks, or
the mounts. The §10 tripwire is not approached: sheets are ordinary maker rows in the app DB,
Lexxy is text-only, and the file grouping is a re-render of data already loaded.

**The four pieces are independent** — they share the project page and nothing else. They can be
built and merged in any order, and the implementation plan should phase them rather than treat
this as one change. Rough ascending cost: status hiding (views only) → file grouping (views + a
role migration) → Lexxy (a gem, two backfills, a v1 shim) → sheets (a new model, controller,
vendored library, and JS surface).

## 2. Decisions (settled — do not relitigate without new information)

| # | Decision | Rationale |
|---|---|---|
| 1 | **Status stays in the DB and in v1; only the web UI hides it** | Removing it is a cross-stack break, not a web change: `client/sync-client/src/maker.rs` declares `pub status: String` with **no `serde(default)`**, so dropping the JSON field is a hard deserialize error, and `client/maker-app/src/projects.js` has a status filter, a badge, a detail-form select, and sends `status: "planning"` on create. The web's own archived test is unchanged from today's (`status == "archived"`). |
| 2 | **Lexxy is text-only — `attachments="false"`** | Lexxy's attachments go through Active Storage: bytes through Rails into a store separate from the file library, invisible to every device mount. §15 stays intact and there is exactly one place a user's file can live. Build-log photos keep using the existing library-backed strip. |
| 3 | **Rich text replaces the `body` column; it does not sit beside it** | `has_rich_text :body` shadows a same-named column: the reader silently returns a different object and `validates :body, presence:` starts validating that object instead. Backfill, then drop the column. |
| 4 | **v1 `body` stays a plain `String` in both directions** | Same reason as #1 — the Rust client declares `pub body: String`, non-optional. Reads serve `to_plain_text`; writes accept a plain string (Action Text takes one directly). Rich formatting is a web-only capability. |
| 5 | **Sheets are free-form, not a BOM editor** | `Maker::Bom`/`BomLine` already exist with a v1 API and typed lines. A generic grid answers cut lists and cost math today; the BOM web UI is a later pass that can reuse the same component with a typed column config. |
| 6 | **Jspreadsheet CE v5 + jsuites, vendored as browser builds** | MIT (§9 ✅), maintained, and formulas are in CE — Pro adds XLSX import/export and collaboration, which we don't need. Both ship UMD browser dists, so this sidesteps the jspm-chunk trap documented in `config/importmap.rb` (the `buffer.js` dangling-import patch that jszip and Maker.js share). |
| 7 | **Sheets get their own full-width page, not a fourth panel** | A real grid inside a panel beside Files/Build log/Tasks is unusable at that width. The project page gets a list of named sheets; the grid opens at `/projects/:slug/sheets/:id`. |
| 8 | **Debounced autosave, last-write-wins** | A spreadsheet that loses an hour of work because you didn't press Save is the worse trade. Single user, no realtime, no locking. |
| 9 | **File grouping reuses the existing `role`** | Roles are already stored per attachment and already derived from the extension, so the grouping is a re-render: no new column and no new derivation logic. (The two *new* roles in §4 do need a data migration — that is about the taxonomy, not about the grouping.) |

## 3. Status pipeline — hidden, not removed

`Maker::Project`, the `status` column, `STATUSES`, the validation, `by_status`, `active`, and
the whole v1 surface are **untouched**. The change is confined to the web views and
`ProjectsController`.

- **`ProjectsController#index`** — `LISTED_STATUSES` goes. `@projects` = projects where
  `status != "archived"`, ordered `updated_at desc`. `@archived_count` stays.
- **`index.html.erb`** — one flat grid; the per-status `<section class="project-group">` blocks go.
- **`show.html.erb`** — the status badge goes; an **Archived** badge renders when
  `status == "archived"`.
- **`_form.html.erb`** — the Status select goes. New projects take the column default
  (`"planning"`); editing from the web leaves status alone.
- **`projects.css`** — the four unused `.badge.status-*` rules go; `.status-archived` stays.
  `.project-group` / `.group-head` go.
- **Archived projects get a home** — `/projects?archived=1` lists them with an **Unarchive**
  button (`unarchive!` → `status: "active", archived_at: nil`). Today the index says "3 archived
  project(s)" with no link; once archive is the only state the web shows, that dead end matters
  more.

**Recorded consequence:** a project set to `paused` or `done` from the desktop app renders as an
ordinary live project on the web, and the web offers no way to reach those values. That is the
accepted cost of decision #1 — it is not a bug to be "fixed" by re-adding the select.

## 4. Files grouped by type

`_attachments.html.erb` splits into headed sub-sections in a fixed order, each its own tile grid,
**empty categories omitted**:

> Models · Images · Instructions · Vector · CAD source · G-code · Archives · Other

Those are display labels over the eight `ROLES` values, in that order: `model`, `image`,
`instructions`, `vector`, `cad_source`, `gcode`, `source_archive` ("Archives"), `other`. No new
role is invented for a heading.

Grouping is `group_by(&:role)` over the already-loaded `@attachments` — no new query, no new
column. The per-tile role badge is removed: the section heading now says it, and the badge was
the only thing it said.

**Two new roles.** `Maker::FileAttachment::ROLE_BY_EXT` today knows nothing about laser or
CAD-source files, so `.svg`, `.dxf`, `.lbrn2`, `.scad`, `.f3d`, `.fcstd` all land in **Other** —
which for a laser- or CAD-heavy project is most of the panel. Add:

- `vector` — `svg`, `dxf`, `lbrn2`
- `cad_source` — `scad`, `f3d`, `fcstd`

`ROLES` gains both. A data migration re-derives `role` for existing rows **currently marked
`other`** via `role_for(name)`, so old attachments land in the new buckets. Rows with any other
role are left alone — re-deriving all of them would undo a deliberate role set by the model-library
importer.

**Blast radius:** `role` is serialized by the v1 API and set by `Maker::AttachToProject` and the
model-library importer, both of which call `role_for`. Both changes are additive — an existing
consumer sees two new string values, and the Rust client types `role` as a plain `String`.

## 5. Lexxy on build-log entries and file notes

### 5.1 Setup

- `gem "lexxy", "~> 0.9.21"` — MIT (§9 ✅).
- `bin/rails action_text:install` — creates `action_text_rich_texts` and the content layout
  partials. **Remove the `trix` pin it adds to `importmap.rb`**; Lexxy replaces the editor and a
  second one would just be dead weight.
- On Rails 8.1 the gem overrides the Action Text form helpers, so `form.rich_text_area :body`
  renders Lexxy with no configuration. (8.2+ registers it as the default adapter instead; either
  way, no config.)
- `attachments="false"` on the editor element — attachments off, per decision #2. Active Storage
  direct-upload is never wired. If Lexxy's bundle imports `@rails/activestorage` unconditionally,
  pin it so the module resolves; direct uploads stay unconfigured regardless.
- CSS via `stylesheet_link_tag`, JS pinned in `importmap.rb` from the gem's asset path.

### 5.2 The two conversions

Both models keep a `body`; both migrate it from a text column to Action Text. **One migration per
model**, each: backfill `action_text_rich_texts` from the current text, then drop the column.

- **`Maker::BuildLogEntry`** — plain text. Newlines must survive the conversion (`\n` → `<br>`,
  paragraphs wrapped) or every existing entry collapses into one line.
- **`Maker::Note`** — the body is **markdown**, rendered today by `NotesHelper#render_note`
  (kramdown → `sanitize`). The backfill runs that same renderer, so existing notes keep their
  formatting instead of displaying literal `**bold**`. After this, `render_note` has no caller;
  remove it, and drop the `kramdown` gem if nothing else uses it.

`validates :body, presence: true` stays on both — Action Text's `RichText` answers `blank?` from
its content, so the validation keeps meaning what it meant.

### 5.3 What does not change

The build log's photo strip (`Maker::FileAttachment` by `node_id`, thumbnails via
`ThumbnailMap`) is untouched and still sits under each entry. It is the *only* way an image gets
into a build log — that is decision #2, stated here because the editor now looks like it should
accept a drop.

### 5.4 v1 API

`V1::Maker::BuildLogEntriesController#entry_json` and
`V1::Maker::ProjectsController#build_log_entry_json` serve `body: entry.body.to_plain_text`.
Writes permit `:body` as before and assign the string straight to the rich text. The wire
contract does not move.

## 6. Project sheets

### 6.1 Model

```
maker_sheets(id, user_id, project_id, name, position, data, created_at, updated_at)
```

`data` is a JSON column holding the whole workbook — cell values plus column headers and widths —
in whatever shape Jspreadsheet round-trips. One project has many named sheets, ordered by
`position`. `Maker::Sheet` validates `name` presence and that the project belongs to the user
(the same `project_belongs_to_user` shape `Maker::Bom` uses).

Nothing here touches the FileLayer port. Sheets are app-DB maker data like tasks and build-log
entries, so they behave identically on all three `LIBRARY_BACKEND` legs.

### 6.2 Surfaces

- **Project page** — a **Sheets** panel listing named sheets with a New sheet button, rename,
  and delete. No grid on this page.
- **`/projects/:slug/sheets/:id`** — full-width grid page.
- **`PATCH /sheets/:id`** — autosave target, JSON in, JSON out.
- **`GET /sheets/:id.csv`** — per-sheet CSV export. Cheap, and keeps the data portable.

Routes are shallow under `projects`, matching `build_log_entries` and `tasks`.

### 6.3 The grid

Jspreadsheet CE v5 + jsuites, both MIT, vendored as browser builds and loaded **on the sheet page
only** (`content_for :head`), not on every page. A `sheet` Stimulus controller instantiates the
grid from `data`, listens for change events, and debounces a `PATCH` ~1s after the last edit,
flipping a Saving… / Saved indicator. Last write wins.

If the vendored dist turns out to be true ESM rather than UMD, it gets pinned in `importmap.rb`
instead of script-tagged — self-contained either way, and the reason for choosing these two
libraries over a jspm-built alternative is precisely that neither route drags in the shared-chunk
problem `importmap.rb` documents at length.

## 7. Testing

Server-side gets real coverage; the grid itself is browser-verified, as the other JS features in
this repo have been.

- **`Maker::Sheet`** — model validations, user scoping. Controller: CRUD, autosave PATCH,
  CSV export, and a cross-user request answering 404 rather than 403-with-existence.
- **The two backfills** — asserted on content, not on row count: a build-log entry with newlines
  keeps its line breaks; a note with markdown renders as HTML, not as literal asterisks. These are
  the tests that would catch the two ways this migration can quietly ruin existing data.
- **v1 contract** — `body` is a `String` on read and accepted as a `String` on write, for both the
  build-log endpoint and the full-project view.
- **Role re-derivation** — a `.dxf` attachment previously `other` becomes `vector`; an attachment
  the importer marked `instructions` is **not** re-derived.
- **Web views** — the project index renders one flat list with no status sections; `?archived=1`
  lists archived projects; the Files panel groups by role and omits empty categories.
- **All three legs** — `bin/rails test`, `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`. Nothing
  here is backend-specific, which is itself the thing worth confirming.

## 8. Not in scope

- **BOM web UI.** The models and v1 API exist; the grid component is deliberately built in a way
  that a later typed-column pass can reuse.
- **Rich text on project descriptions or tasks.** Considered and declined — descriptions are a
  line or two, and tasks are title-only today.
- **Library-backed rich-text attachments.** The "right" long-term answer (a Lexxy uploader that
  pushes through the existing per-backend upload flow and inserts an Action Text attachment
  referencing a `node_id`) is recorded here and not built: it is the largest single piece of work
  in this area and touches all three upload paths.
- **Removing `status` from v1 or the desktop app.** Decision #1.
- **Realtime or multi-user sheet editing.**

## 9. Risks

| Risk | Mitigation |
|---|---|
| The backfills are one-way — a bad conversion loses formatting on every existing entry | Content-level tests before the column drop; the two failure modes (collapsed newlines, literal markdown) are each pinned by a test |
| Lexxy is pre-1.0 (`0.9.x`) and its API may move | Pinned pessimistically; the integration surface is one helper call and one attribute |
| Jspreadsheet CE v5's dist format may not be what the vendoring assumes | Both routes work (script tag reading `window.jspreadsheet`, or an importmap pin); the choice is made at implementation time against the actual file |
| Autosave silently failing looks identical to autosave working | The indicator has an error state, not just Saving/Saved |
| A large `data` blob on a sheet with thousands of rows | Accepted. Single-user scale; if it bites, the fix is a normalized cells table behind the same controller |
