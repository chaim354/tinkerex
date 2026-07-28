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
  formatting instead of displaying literal `**bold**`.

**`render_note` and kramdown both stay.** `app/views/models/show.html.erb:95` renders
`Maker::Model#notes` — a separate plain `text` column on a different model — through the same
helper, so it keeps a caller and `test/helpers/notes_helper_test.rb` keeps passing. Removing
either would break the model detail page.

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
- **Reconciling the two file-type vocabularies.** Surfaced by §4's whole-change review, recorded
  rather than fixed: `FilesHelper::EXT_FAMILIES` (the Files-page filter chips) and
  `Maker::FileAttachment::ROLE_LABELS` (the project panel's group headings) now describe overlapping
  files in different words — `.svg`/`.dxf`/`.lbrn2` are "2D / laser" on one page and "Vector" on the
  other — and the five `cad_source` extensions have **no chip family at all**, so a project gets a
  first-class "CAD source" section with no library-wide one-click filter to match. Nothing is
  broken: the chips' free-text `add_ext` field still reaches those files by that helper's own
  design. Both predate this work and neither surface was in scope here. Worth a deliberate decision
  — one vocabulary or two, argued — the next time either is touched.

## 9. Risks

| Risk | Mitigation |
|---|---|
| The backfills are one-way — a bad conversion loses formatting on every existing entry | Content-level tests before the column drop; the two failure modes (collapsed newlines, literal markdown) are each pinned by a test |
| **Note HTML freezes at migration time.** The old page ran `render_note` at *render* time, every view — so any later improvement to the renderer (a kramdown upgrade, a sanitizer allow-list change) retroactively improved every existing note. After the migration the HTML is stored once and never re-rendered, so it never will again. | **Accepted, not mitigated** — it is the unavoidable consequence of moving to rich text at all: you cannot have both "the user edits this as WYSIWYG" and "it still tracks a live markdown renderer". Recorded because it is a genuine user-visible behaviour change with no other trail. |
| Lexxy is pre-1.0 (`0.9.x`) and its API may move | Pinned pessimistically; the integration surface is one helper call and one attribute |
| **`attachments="false"` is a UI restriction, not an enforcement boundary — OPEN, needs a decision** | See §9a below. Not mitigated by this work. |
| Jspreadsheet CE v5's dist format may not be what the vendoring assumes | Both routes work (script tag reading `window.jspreadsheet`, or an importmap pin); the choice is made at implementation time against the actual file |
| Autosave silently failing looks identical to autosave working | The indicator has an error state, not just Saving/Saved |
| A large `data` blob on a sheet with thousands of rows | Accepted. Single-user scale; if it bites, the fix is a normalized cells table behind the same controller |

## 9a. OPEN: `attachments="false"` does not survive leaving the editor

Found by Task 4/5's review, **by exercising it rather than reading it**. Decision #2 says attachments
are off so that Lexxy's Active Storage path — bytes through Rails, into a store separate from the
file library — is never used, citing §15 and the FileLayer port. **The client-side half of that is
solid; the server-side half does not exist.**

**What was verified to hold.** `attachments="false"` genuinely disables the editor UI. Lexxy parses
the attribute with `JSON.parse`, so the *string* `"false"` really does become boolean `false` (not
the classic truthy-string bug). Every creation path funnels through one chokepoint,
`Contents#uploadFiles`, which bails on `!supportsAttachments`; drag/drop listeners are never
registered, paste short-circuits, the whole `AttachmentsExtension` is conditionally disabled, and CSS
hides the toolbar buttons. Nothing in this app's JS bypasses it.

**What was verified NOT to hold — both demonstrated, not reasoned:**

1. **`POST /rails/active_storage/direct_uploads` is live and unauthenticated.**
   `ActiveStorage::DirectUploadsController` descends from `ActiveStorage::BaseController`, *not* this
   app's `ApplicationController`, and adds no authentication. An integration session that never signs
   in POSTs successfully, mints a real `ActiveStorage::Blob`, and gets a signed upload URL back. That
   is an anonymous write surface into storage through Rails — the shape §15 exists to prevent.
2. **The server does not filter attachment markup out of a body.** `NotesController#create` and
   `Projects::BuildLogEntriesController#create` assign the raw `body` param. Action Text's own
   sanitizer **preserves** `<action-text-attachment sgid="…">`, so a signed-in user posting the form
   field directly (curl, devtools, a modified fetch) creates a real, rendering attachment — the
   editor never involved.

**Scope, honestly:** the route is **pre-existing** — Active Storage has been installed since the
preview pipeline, and its engine mounts that route automatically. What this work changed is that
there is now a **user-writable field where an attachment renders**, which turns a dormant route into
a reachable one. Attachment injection is self-scoped (your own notes and entries); anonymous blob
creation is not.

**This is left open deliberately rather than fixed in passing**, because it is a security-posture
decision about storage that reaches past this feature. The options:

- **(a) Strip server-side.** Remove `<action-text-attachment>` from `body` before save on both
  models. Closes injection, cheap, keeps the route.
- **(b) Gate the route.** Constrain or remove `rails/active_storage/direct_uploads`. Closes anonymous
  blob creation — the §15 half. Nothing in this app appears to use direct uploads (previews attach
  server-side), so the exposure of removing it looks low, but that needs checking rather than
  assuming.
- **(c) Both**, which is the only combination that makes decision #2's stated rationale true.
- **(d) Accept and document** — reasonable for a single-user self-hosted deployment, much less so for
  the managed/SaaS mode §7 describes.

**Do not let this be read as closed by decision #2's wording.** That decision is correct about what
the editor does and silent about what the server accepts.

## 9b. OPEN: formulas need a SECOND package, and it has no licence

Decision #6 says Jspreadsheet CE is "MIT (§9 ✅) … and formulas are in CE — Pro adds XLSX
import/export and collaboration, which we don't need." **The first half is true; the second half is
wrong**, and it was the reason the library was chosen at all.

**What was verified, independently and from primary sources:**

- `jspreadsheet-ce@5.0.4`'s own `package.json` declares **two** runtime dependencies of equal
  standing: `"jsuites": "^5.12.0"` **and** `"@jspreadsheet/formula": "^2.0.2"`. The bundle carries
  two identical peer shims, one per dependency:
  `if(!jSuites&&"function"==typeof require)var jSuites=require("jsuites")` and
  `if(!formula&&"function"==typeof require)var formula=require("@jspreadsheet/formula")`.
- Only `jsuites` was vendored. With `window.formula` undefined, **every formula renders `#ERROR`** —
  including `=1+1`, which has no cell references, so this is not a cross-reference problem. Observed
  live in the browser, not inferred.
- **`@jspreadsheet/formula@2.0.2` publishes with no licence grant at all:** the npm registry's
  `license` field is absent, `/LICENSE` 404s on the CDN, and the bundle carries no licence banner
  (grepping it for `licen[sc]e` returns nothing).
- Its GitHub README describes a **Basic (MIT) / Premium (paid)** split and states: *"This plugin
  requires a license that should be associated with one specified domain. If you need a license for
  redistribution or SaaS, please keep in touch."* Which of the two the unlabelled npm artifact is,
  the artifact does not say.

**Why this is not a mechanical fix.** §9 is a hard constraint on *shipped artifacts*, and vendoring
puts the file in this repo. An artifact with no licence grant is worse than a copyleft one: copyleft
at least grants something. And this product has a managed/SaaS mode (§7) — precisely the case the
README says needs a licence.

**Storage is unaffected, and that was the thing worth protecting.** The autosave persists raw
formula text (`getData(false, false)` reads `options.data`, which `updateCell` writes before the
evaluator runs and which the evaluator never writes back). Verified: the DB row holds `=A1+B1`
literally while the cell displays. So **nothing has been destroyed** and any of the options below
can be taken later without data loss.

**Options, none taken:**

- **(a) Ship sheets without formulas.** Everything else works — typing, autosave, insert/delete
  rows and columns, rename, CSV. Cost: `=1+1` shows `#ERROR`, which is a bad thing for a user to
  meet; worth suppressing the formula prefix or saying so in the UI.
- **(b) Clarify the licence with Jspreadsheet** and vendor it if Basic-as-published is genuinely MIT.
  A one-email answer that unblocks the original design.
- **(c) Wire a different, clearly-MIT engine** (e.g. formula.js). The grid reads a global `formula`
  with a specific API, so this is real work, not a swap.
- **(d) Reconsider the grid library** — but CE itself is fine and MIT; only the formula plugin is in
  question, so this is the heaviest option for the least reason.

**Do not let decision #6 be read as settled.** It is correct about the grid and wrong about formulas.

### 9b.1 RESOLVED: wire `hot-formula-parser` (MIT) behind the grid's own hook

Decision (user, 2026-07-28): **option (c)** — a different, clearly-MIT engine, rather than vendoring
the unlicensed one or shipping without formulas.

**The grid's formula hook, reverse-engineered from the vendored bundle** (all of this was read out of
`vendor/javascript/jspreadsheet.js`, not from documentation, and it is the expensive part of this
work):

```js
res = formula(expression.substr(1), formulaExpressions, x, y, obj)
if (typeof res === "function") res = "#ERROR"      // and a throw is caught → "#ERROR"
```

- **The grid resolves cell references itself.** Before calling, it strips `$` (`/\$?([A-Z]+)\$?([0-9]+)/g`
  → `$1$2`), **expands ranges** — `SUM(A1:A5)` becomes `SUM(A1,A2,A3,A4,A5)` — and builds
  `formulaExpressions`, a map of every remaining cell token to its value. So the engine's job is
  **expression evaluation against an injected scope**, not reference resolution. That is a far
  smaller contract than "be a spreadsheet engine".
- **Values arrive pre-formatted for `eval`**, which is the trap: numbers come as numbers, blanks as
  `null`, and **strings come wrapped in literal double quotes** (`'"text"'`). A parser-based engine
  must unwrap them; passing them through yields quoted-looking output.
- **The shims sit OUTSIDE the UMD factory**, at script top level — verified by reading the bytes
  before `!function(e,t){…}(this,…)`. So `var formula` at top level *is* `window.formula`, and
  setting the global before `jspreadsheet.js` loads works exactly the way `jsuites` already does.
  Load order becomes: `jsuites` → `formula-parser` → the adapter → `jspreadsheet`.

**Why `hot-formula-parser@4.0.0`:** MIT, ships a self-contained UMD browser build
(`dist/formula-parser.min.js`) setting `window.formulaParser`, and its bundled dependencies are MIT
too (`@handsontable/formulajs`, `tiny-emitter`) — which matters because they ship inside the file
(§9 is about artifacts, not just direct deps). It resolves refs through a `callCellValue` callback,
which is exactly the seam needed to feed it `formulaExpressions`.

**Why not a `new Function` adapter over `@formulajs/formulajs`** (also MIT, and simpler): Excel and
JavaScript disagree on operators, silently. `&` is concatenation in Excel and bitwise-AND in JS; `^`
is exponentiation vs XOR; `<>` is not-equal vs invalid; `=` is equality vs assignment. Every one of
those evaluates to something rather than erroring — the exact silently-wrong failure mode this whole
arc has been fighting. `hot-formula-parser` implements the Excel semantics (it has per-operator
modules: `ampersand.js`, `equal.js`, …).

**Return the engine's error string rather than throwing.** hot-formula-parser yields real Excel error
values (`#DIV/0!`, `#NAME?`, `#VALUE!`); returning them shows the user what is actually wrong,
whereas throwing collapses everything to the grid's generic `#ERROR`.

**CSP is not a constraint here** — `config/initializers/content_security_policy.rb` is entirely
commented out, and the grid itself already calls `eval()` internally regardless.
