# Shelves, model cards and chosen previews — design

2026-10-20. Three independent parts, one branch (`claude/shelves-and-model-previews`).

The owner's request, verbatim: "Get rid of shelves and make filings named shelves and be able to add
new shelves. Get rid of tag in corner of models and why is the preview not same as square. Also
allow a new preview to be made if a person wants a different angle. Also in the shelves add a
default view type for each and allow the user to add shelf groups."

Decisions taken with the owner before this was written:

| question | answer |
|---|---|
| What decides which folders are 3D models once the old Shelves page goes? | A built-in rule — today's four defaults, fixed in code |
| What is a shelf group? | A section on the project page; folders on disk stay flat |
| Where does a shelf's default view apply? | Project page folder panels |
| How is a different preview angle chosen? | Rotate in the 3D viewer, "Use this view as preview" |

## Part 1 — Model cards

`app/views/models/_card.html.erb` is rendered only by the 3D models view
(`app/views/files/models/index.html.erb`).

1. **Remove the print-status badge** (`span.badge.mstatus-*`, absolutely positioned top-left by
   `pages/models.css`). Status stays filterable by the chips above the grid and is shown on the
   model's own page. The two `.model-card .badge` CSS rules go with it.
2. **Square preview.** The thumbnail box is `.project-card .thumb { width: 100%; height: 120px }`
   in a grid whose columns are at least 150px wide, so a model's square render sits in a wide,
   short box. For `.model-card` only: `height: auto; aspect-ratio: 1 / 1`. Project cards and the
   public explore cards are unchanged.

## Part 2 — "Use this view as preview"

**Where.** Every place `modelviewer_controller.js` renders a single library file that has a node
id: the file page's 3D viewer (`files/viewers/_model3d.html.erb`) and the model page's viewer
(`models/show.html.erb`) when it shows one file. A button, "Use this view as preview", sits in the
viewer's controls. A second button, "Back to automatic preview", appears only when the file's
current thumbnail came from the viewer.

**Capture.** `viewer.GetViewer().GetImageAsDataUrl(512, 512, false)` (o3dv's own API, present in
the vendored `o3dv.js`) → a PNG blob → `POST /files/:node_id/preview` (session-authed web route,
§14d — never the v1 API) as multipart, with the CSRF token.

**Server.** A new action on a small controller (e.g. `Files::PreviewsController#create` /
`#destroy`):

- the node must be the user's own LIVE file (scoped through `current_user`; a foreign or
  tombstoned id 404s);
- the upload must be a PNG by magic bytes, at most 2 MB, and its IHDR dimensions at most
  1024×1024 — anything else is a 422 with nothing written;
- it writes the `kind: "thumbnail"` `Maker::Preview` row for `(user, node_id)` (one row per
  user/node/kind, §14b): attach the PNG as `asset`, `status: "ready"`, `version_id` = the node's
  CURRENT `content_token`, `width`/`height` from the PNG, and **`source: "viewer"`**;
- `#destroy` ("Back to automatic preview") sets `source: "renderer"` and enqueues the normal
  render through `Maker::Previews::Enqueue` with its own semantics.

The PNG passes through Rails. §15 ("keep bytes out of Rails") is about LIBRARY bytes; a preview is
app-owned derived data stored in Active Storage, and `POST /v1/maker/previews` already accepts a
device-rendered preview the same way.

**New column** `maker_previews.source` — string, not null, default `"renderer"`, values
`renderer | viewer`, validated by inclusion.

**What keeps it.** A viewer preview is current for as long as its `version_id` equals the node's
content token. `Maker::Previews::Enqueue` (and therefore the scan's in-place-change enqueue, the
missing-preview backfill and a renderer-revision bump) must treat a `source: "viewer"` row whose
`version_id` matches as current: no job, no `rebuilding`, the asset untouched. When the content
changes the row is repointed exactly as today and `source` resets to `"renderer"` — the old angle
is a picture of geometry that no longer exists. `GeneratePreviewJob`'s compare-and-set must also
refuse to overwrite a viewer row (a render queued before the user clicked must not land on top of
their choice).

**Scope.** `thumbnail` kind only. The Measure view's `geometry` kind is untouched (§14h).

## Part 3 — Shelves

### 3a. The old Shelves go; model detection becomes a built-in rule

- `Maker::ModelIntake` reads a constant instead of `user.maker_shelves`:
  `MODEL_SHELVES = [ "", "*", "Models", "Projects/*/models" ]` (the current `Maker::Shelf::SEEDS`,
  with their existing comment about why `*` and `Projects/*/models` both matter). The pattern
  matcher (`Maker::Shelf.matches?`) moves with it.
- Deleted: `Settings::ShelvesController`, `settings/shelves/index` (the old page), the
  `maker_shelves` table and model, `users.shelves_seeded_at`, `Shelf.seed_once!` and its call in
  the sweep, the 3D models page's "Which folders count as models: Settings → Shelves" hint.
- Measured 2026-10-20 on all three live Unraid deployments: every user's shelves are exactly the
  four seeds, so the built-in rule changes no one's catalog.
- `docs/invariants/model-intake.md` is rewritten for the fixed rule: the seed-once, wildcard
  validation and live/missing-indicator bullets describe code that no longer exists and are
  removed; nearest-shelf, node-id identity, and everything else stand.

### 3b. Filing becomes Shelves

- The page `settings/filing_rules#index` becomes **Shelves** at `/settings/shelves`;
  `/settings/filing` 301s there. Rule chips keep their existing create/update/destroy routes. The
  settings hub shows one "Shelves" row (count of shelves); the "Filing" row goes. The help page and
  `shared/_where_files_come_from` say "Shelves".
- **A shelf is a row**: `maker_shelves (user_id, name, default_view, shelf_group_id, position)`,
  unique `(user_id, name)`. `name` follows `Maker::FilingRule`'s existing folder rule — one
  lowercase segment, `valid_leaf_name?` and not `ReservedNames.reserved?` — by calling the SAME
  check, not a copy.
- **Filing rules keep their `folder` string.** `Maker::ProjectFolders.folder_for` and the intake
  sweep are untouched. The join is by name.
- **No drift between the two:** reading the shelves (`Maker::Shelves.for(user)`) first ensures a
  row exists for every folder a rule names, plus `other` (the fallback, which no rule names on the
  live data), with `insert_all` (conflicts do nothing). Seeding is therefore derived from the rules
  that `Maker::FilingRules.seed!` already seeds — there is no second seed list.
- **Add shelf**: a name field at the foot of the page. A new shelf has no rules until extensions
  are added to its card; the sweep creates the folder in a project only when a file files there.
- **Remove shelf**: destroys its rules and the row in one transaction, after a confirm saying its
  extensions will file into `other`. `other` cannot be removed (no button; the controller refuses).
- **No rename** — a shelf's name is a folder name inside every project on disk.

### 3c. Default view per shelf

- `default_view` is `nil` (shown as "Automatic") or one of `Maker::Project::VIEWS`
  (`tiles list browser`). A select on each card, saved by `PATCH /settings/shelves/:id`.
- On a project page a folder panel's view is, in order: the maker's choice on that project
  (`panels["views"]`) → the shelf default for a shelf whose name equals the folder's name →
  today's automatic default (`browser` for a working tree, else `tiles`).
- Plumbing: `ProjectFolderListing#panel_folders` carries the folder's name as a third element;
  `Maker::ProjectKind.layout_for` takes `shelves:` (default `{}` — every existing caller keeps
  today's layout) mapping folder name → `{ view:, group: }`; `Layout#view_for` consults it.
  `ProjectsController#show`, `Projects::LayoutScoped` and `Maker::PublicProject` pass it (the
  owner's shelves shape the public page too). One query for shelves+groups per page, constant in
  the number of panels.

### 3d. Shelf groups

- `maker_shelf_groups (user_id, name, position)`, unique `(user_id, name)`; `name` is display text
  (1–40 chars, stripped). A shelf belongs to at most one group (`shelf_group_id` nullable,
  `dependent: :nullify` from the group).
- **Settings page:** ungrouped shelves first, then one heading per group with its shelves'
  cards. Each card has a group select (None or a group). "Add group" form; each group heading has
  Rename and Delete (delete leaves its shelves ungrouped, after a confirm).
- **Project page:** folder panels whose shelf is in a group are placed together in the DEFAULT
  arrangement (ungrouped folders in disk order, then each group's folders in group position
  order), spliced after Files exactly where folders go today. When rendering, a full-width heading
  with the group's name is drawn before each run of consecutive visible panels belonging to that
  group. A maker's saved order still wins; if it splits a group, each run gets its own heading.
  Headings are not drawn in the layout editor (it arranges panels, and a heading is not one).
  The public page draws them too, through the same `_panel_groups` partial.

### Not in scope

Renaming a shelf; groups as tabs; nested folders on disk; a default view on the Files page;
viewer-chosen previews for kinds other than `thumbnail`.

## Testing

Request tests assert the RENDERED field names of every new form (CLAUDE.md §14d). Model tests for
`Maker::Shelf`/`Maker::ShelfGroup` validation and the derived-rows read. A project-page test for
the shelf default view and its precedence below a per-project choice, and for the group heading
runs. `Enqueue` tests for the viewer-preview skip and the reset on content change. The upload
endpoint's refusals (foreign node, non-PNG, oversize). Every guard mutation-checked (§15). Bare
`bin/ci`, all three backend legs with equal RUN counts. The new tables get the four derived guards
(cross-tenant FK, referential integrity, tenant cleanup, structural orphan).
