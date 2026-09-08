# Stage 4 — the bench maker's loop — slice overview

> **For agentic workers:** this file is NOT executable on its own. It fixes the slice order, the
> shared interfaces and each slice's territory so the per-slice plans cannot drift apart. **Read
> this, then execute the plan for your slice.** In this repo `.claude/commands/execute-plan.md`
> overrides the generic subagent loop: batch by file, dispatch disjoint tasks in parallel, no
> spec-compliance stage, one capped quality review per task with its mutations run and reported.

**Design:** [`docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md`](../specs/2026-09-07-stage-4-bench-maker-design.md)
— §2 holds five proposed decisions (D1–D5); each slice below names the one it depends on, and the
decision is confirmed or flipped before that slice's plan is written, never inside it.

**Stories:** [`docs/user-stories.md`](../../user-stories.md). Every slice's close-out re-tags the
stories it names. The ids are cited from the spec, the plans and the record — **never renumber**.

**Goal:** the maker who saves from LightBurn onto the NAS and opens the app to look, measure,
generate and show gets a project page that fits the project, files that land where they belong, a
round trip that closes, and a public page that needs no second tool to write.

**Architecture:** every slice is web surfaces over data the app already keeps, plus at most two
columns; nothing crosses the wire to the sync server; bytes that land on the share go through the
port. The project page keeps one `PageNodes` union and one `ThumbnailMap`, and every new panel
joins them.

**Tech stack:** Rails 8, Hotwire, Minitest, the vendored CodeMirror bundle (S4-4), the existing
viewer controllers (S4-5). No new gem. No new JS dependency.

---

## Slice order — do not resequence without reading this

| slice | plan | delivers | depends on | risk |
|---|---|---|---|---|
| S4-1 | `2026-09-07-stage-4-s1-project-page.md` | hero, photos, README card (root repo included), quiet panels, list-view menu | — | **landed** 2026-09-07, PR #334 |
| S4-2 | `2026-09-07-stage-4-s2-filing.md` | roles for `.mage` `.lbrn` `.ai`, KiCad rules, board zips → `pcb/`, grouped settings, sweep opt-out and feedback, build-output display rule | — | **landed** 2026-09-07, PR #335 |
| S4-3 | `2026-09-07-stage-4-s3-round-trip.md` | path + copy, self-refreshing file page, Save-to-library, honest Rescan | — | **landed** 2026-09-07, PR #336 |
| S4-4 | `2026-09-07-stage-4-s4-documentation.md` | README editor for any project (D3, the README door only), owner preview, publish panel, namespaced anchors | D3; S4-1's README card | **landed** 2026-09-07, PR #337 |
| S4-5 | `2026-09-07-stage-4-s5-public-viewers.md` | public file page with the eight shared viewer partials (D5), covers on `/u/:handle`, hero, public header | D5 | **landed** 2026-09-07, PR #338 |
| S4-6 | `…-s6-adopt-anywhere.md` (to write) | adopt in place (D1), status, make-current, New badge, Not-a-project, switch confirmations | D1 | moderate: a folder outside `Projects/` as `folder_node_id` |
| S4-7 | `…-s7-kinds.md` (to write) | `kind` + presets, per-project panel overrides | D4; S4-1's quiet panels | moderate: the panel list becomes data |
| S4-8 | `…-s8-connections.md` (to write) | `maker_file_links`, lineage on file pages, search over notes/README | S4-3's Save-to-library (a writer of links) | moderate: new table, needs the four derived guards (see below) |

**S4-1 first, and S4-7 after it**, because S4-7 turns the seven hard-coded `render` calls into a
loop over a panel list with per-project overrides, and the quiet-when-empty state S4-1 introduces
is what makes "hidden" and "empty" two different things rather than one. Doing S4-7 first would
build the loop over panels that still shout when empty, then rebuild it.

**S4-4 after S4-1**, because the README editor mounts on the README card S4-1 puts at the top of
Files. **S4-8 after S4-3**, because Save-to-library is the first automatic writer of a
`derived_from` link and the table should land with a writer, not before one.

S4-2, S4-3, S4-5 and S4-6 are independent of each other and of S4-1; they may run in any order or
in parallel worktrees, subject to one full-suite run at a time.

---

## Shared interfaces — defined once, used by every slice

Any slice plan that disagrees with this section is wrong. Change it here first.

### `Maker::ProjectFolderListing#root_repo?` (S4-1 creates; S4-4, S4-6 consume)

```ruby
# Is the project's folder ITSELF a working tree — a `.git` marker child of folder_node_id? The
# walk already asks this of every child dir it enters (working_tree?); this asks it once of the
# root, which collect_dirs enters but never flags. In memory, no query.
def root_repo? = @root_repo   # false when the folder is not available
```

S4-4's README editor asks it to decide whether a save is a pending git edit (repo root) or a
plain port write. S4-6's "Not a project" and "adopt in place" read it to label a repository
folder as such.

### `Maker::ProjectPhotos.rows(listing:, entries:, page_nodes:)` (S4-1 creates; S4-5 keeps public on it)

```ruby
module Maker
  module ProjectPhotos
    # Every image-role row in the folder plus every live entry photo, deduped, name-ordered.
    # The ONE definition — Maker::PublicProject#photo_rows delegates here, and the private
    # project page reads it too. In memory over inputs the page already loaded: no query.
    def self.rows(listing:, entries:, page_nodes:)
```

### The README card partial (S4-1 creates; S4-4 mounts the editor on it)

`app/views/projects/_readme_card.html.erb`, locals `readme:` (a `Maker::Readme` result or nil)
and `editable:` (S4-1 always passes `false`; S4-4 flips it). It renders **inside** the Files panel,
above the groups. For a root repository the full `projects/_repo_card` renders instead, with the
same `.readme` details inside it — S4-4 mounts the editor on `.readme` in both.

### The quiet-panel contract (S4-1 creates; S4-7 reads)

A secondary panel is `section.panel.<name>-panel.panel--quiet` when it has nothing to show: the
`h2` and exactly one add control (`details.composer > summary.btn` or a one-field form), nothing
else. S4-7's per-project `panels` overrides decide whether a panel is **rendered**; the quiet
state decides how an **empty rendered** panel looks. They must stay two questions.

### Filing-rule keys (S4-2 creates; S4-8 does not touch)

`Maker::FilingRule::KEY_RE = /\A[a-z0-9_]{1,12}\z/` — the rule table's own key rule, wider than
`FilesController::EXT_RE` on purpose so `kicad_sch`/`kicad_pcb` can carry a rule. `ROLE_BY_EXT`
keeps `EXT_RE`; `files-preview.md` records why the two differ.

### `Maker::FileLink` (S4-8 creates)

```ruby
# maker_file_links(user_id, from_node_id, to_node_id, kind, created_at)
# kind ∈ %w[derived_from photo_of]; unique (user_id, from_node_id, to_node_id, kind)
# Both node columns are BARE node_id strings with no FK — the same convention every maker table
# keeps (§5's content_token note; maker_file_attachments). Liveness is answered by nodes.present
# at read time, never by the row.
```

The guards a new table owes are SIX here, not the checklist's four, and the S4-8 plan found why:
`structural_orphan_test.rb` selects only edges whose parent ends in `.id`, so a table keyed by two bare
`node_id` strings contributes no structural edge at all and its `maker_connections` case is NOT the
model to copy. The real union: the schema map (`bin/rails schema:map`), tenant cleanup, the dead-node
reaper (sweeping rows whose node is `reapable?`, from EITHER column), `page_query_budget_test.rb`
(links grow per file), the template sweep (every new partial's populated branch), and the index-prefix
guard (no bare `user_id` index beside the unique one).

---

## Rules for every slice

- **Read the invariants file before touching its paths.** S4-2: `docs/invariants/project-intake.md`
  and `docs/invariants/files-preview.md`. S4-3, S4-4: `docs/invariants/git-editing.md` and §14a's
  `replace:` bullet. S4-4, S4-5: §14d's `Public::` rule and `docs/invariants/design-system.md`.
  S4-6: `docs/invariants/project-intake.md` and `docs/invariants/model-intake.md` (the `*` shelf).
- **Tests run with `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`**; one full-suite run at a
  time; from a worktree `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync
  bin/ci`. The three backend legs must report identical run counts.
- **Fixtures are port-free unless the test owns a share library.** A project folder in a request
  test is `project_folder_rows!(user, project)`, never `ensure_library_folder!`; a real README or
  git repo needs `use_fresh_share_library!` plus `Library::ScanJob` (the idiom in
  `test/integration/web/project_repo_card_test.rb`).
- **Upload-control assertions branch on `port_writable?`**; chunk_remote renders the presigned
  flow (memory: `upload-form-assertions-must-branch-on-port-writable`).
- **Every guard is made to fail** and the output reported. `git add` a new file before a
  mutation check; restore with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after an
  equal-length restore.
- **When a change invalidates a documented behaviour, the same task sweeps every file that
  documents it** — template comments, invariants files, this overview.
- **A slice with a migration regenerates `docs/schema-map.html` in the same task** (`bin/rails
  schema:map`, then commit it): `test/schema_map_test.rb` fails the full gate when the checked-in map
  lags `db/schema.rb`, and no per-task test run reaches it — S4-2 learned this at its gate.
- **Close-out re-tags the stories** the slice named in `docs/user-stories.md`, with the new
  evidence, in the same PR; then `bin/log arc --from-pr <n>` as the PR opens.

---

## Territory per slice

### S4-1 — the project page shows what matters

Files: `app/services/maker/project_folder_listing.rb` (`root_repo?`), new
`app/services/maker/project_photos.rb`, `app/services/maker/public_project.rb` (delegate
`photo_rows`), `app/controllers/projects_controller.rb#show` (root card, readme, photos, cover in
the unions), `app/views/projects/show.html.erb` (hero, photos), new `_hero.html.erb`,
`_photos.html.erb`, `_readme_card.html.erb`, `_attachments.html.erb` (card slot, head links,
caption), `_file_rows.html.erb` (menu data), the six panel partials (quiet state),
`app/assets/stylesheets/pages/projects.css`. Tests: `project_page_test.rb`,
`project_attachments_test.rb`, `project_repo_card_test.rb`, `page_query_budget_test.rb` (cover +
photos in the seed), `template_hygiene_test.rb` (the new partials' populated branches), the phone
sweep in `test/system/shell_test.rb` if the hero widens anything.

### S4-2 — filing that matches the bench

Files: `app/models/maker/file_attachment.rb` (`ROLE_BY_EXT`: `mage`, `lbrn`, `ai`; a `cnc_design`
role → `cnc/`), `app/services/maker/model_intake.rb` (`EXCLUDED_ROLES` gains the new role),
`app/services/maker/previews/registry.rb` + `previews/pdf.rb` (`.ai` when bytes start `%PDF-`),
`app/models/maker/filing_rule.rb` (`KEY_RE`), `app/services/maker/filing_rules.rb` (seed the new
keys for already-seeded users — a data migration, the `RederiveModelRolesAndSeedFilingRules`
pattern), `app/services/maker/project_intake.rb` (board zips via `Maker::GerberArchive.for` — `.archive?` is
name-only — bounded, in `#place` alone; `autofile`; `Result#conflict_folders`; `record_sweep!`, the one
writer of `last_swept_at`/`last_sweep_moves`), `app/controllers/concerns/
project_folder_intake.rb` (a flash that names moves), `app/views/settings/filing_rules/
index.html.erb` (one card per folder), new `app/services/library/build_output.rb` (`node_modules`, `__pycache__`; `build` deliberately not),
`app/models/node.rb` (`visible_entries`), `Maker::ProjectFolderListing#hidden_dir?`;
`search_controller.rb` needed only a comment (it already reads the shared scope), `app/views/projects/_attachments.html.erb` (the
sweep line), two migrations. Tests: `filing_rule_test.rb`, `filing_rules_test.rb`,
`project_intake_test.rb`, `settings_filing_test.rb`, `previews/pdf_test.rb`, `node_test.rb`,
`files_search_test.rb`, the three `docs/invariants/*` files that describe the vocabulary.

### S4-3 — the round trip closes

Files: `app/views/files/show.html.erb` (path row + copy; a `thumbs` poll on the poster), new
`app/javascript/controllers/copy_controller.js`, `app/controllers/files_controller.rb#update`
(re-enqueue), `measure_controller.js` + `lib/export_svg.js` + `lib/print_sheet.js` (Save to
library: hand the Blob to `uploader_controller.js`'s two-door flow with `parent_node_id` = the
source's parent), `app/jobs/library/scan_job.rb` (stamp `users.library_scanned_at`), a
`GET /files/scan_status` JSON route read by `scanreload_controller.js`, one migration. Tests:
`files_show_test.rb`, `measure` system tests, `scan_button` tests, `stimulus_hygiene_test.rb`
(derives the new controller).

### S4-4 — documentation on your own page

**As landed (2026-09-07).** Files: `app/views/projects/_readme_editor.html.erb` mounted from both
README cards (`_readme_card`, `_repo_card`) with `shared/_no_history_note.html.erb` gated on
`capabilities.versioned?`; new `app/javascript/controllers/readme_controller.js` over the vendored
CodeMirror bundle (no new pin); `app/controllers/projects/readmes_controller.rb` (`PATCH
/projects/:id/readme`, no node id from the client — the row comes from `Maker::Readme.row_in` over
the project's own listing) calling **`Maker::TextSave`**, the one save `FilesController#update` also
calls (stale check, `replace: true`, the pending git edit, the preview re-enqueue through
`LibraryOutput.enqueue_preview`); `ProjectsController#preview` + `projects/preview.html.erb` +
`_preview_banner.html.erb` over **`public/projects/_page.html.erb`**, extracted from the public
page as a pure move (`Public::BaseController` untouched); `projects/_publish.html.erb` (visibility
with meanings, licence, inline handle claim via `Settings::HandlesController#return_path`, URL +
Copy, unlisted link + Copy + New link → `Projects::UnlistedTokensController#create`) with visibility
and licence removed from `_form.html.erb`; `app/services/maker/markdown.rb` (heading ids kept,
**namespaced `user-content-<slug>`** — a bare `id="project-tasks"` collided with the tasks panel's
Turbo target — in-document `#links` rewritten through the same slug function, duplicates suffixed).
Tests: `readme_edit_test.rb`, `readme_editor_test.rb` (system: the copy-back), `text_save_test.rb`,
`project_preview_test.rb`, `publishing_test.rb`, `markdown_test.rb` (+ a static guard keeping
`user-content-` out of app views and JS), the preview's query budget, the phone sweep opening the
editor (which found and fixed a grid min-content overflow), `docs/invariants/git-editing.md` (the
Markdown exception, argued; story 2.13 deliberately not moved). Open work filed: `tinkerex#276`
(the stale check compares the catalog's token).

### S4-5 — visitors see what you see

**As landed (2026-09-07).** Files: `app/controllers/concerns/file_preview.rb` (`preview_kind`, the
Gerber layer walk and the three extension vocabularies, which `FilesController` re-exposes by
identity-asserted ALIAS) and the eight strict-locals viewer partials `app/views/files/viewers/_image
_pdf _kicanvas _gerber _code _model3d _measure _static`, rendered by `files/show.html.erb` and by the
new `app/views/public/files/view.html.erb` (named after the action; `Public::FilesController#view`,
plus `#geometry`, a poll that never writes — the page enqueues one geometry job when none is
current); the `/view` and `/geometry` routes sit ABOVE `files#show` because `(/*filename)` would
otherwise swallow them; `Maker::PublicProject#view_url_for`, `#layer_url_for` (a job's published
siblings only) and `#cover_node`; `_measure.html.erb`'s required `save:` local (false publicly: no
Save controls, no upload URLs) with `measure_controller.js`'s `has*Target` guards; covers on
`public/_project_card.html.erb` resolved in `Public::UsersController` only (Amendment 9 — `/explore`
keeps the placeholder, measured by the budget test); the hero on `public/projects/_page.html.erb`;
`layouts/_public_header.html.erb` on the anonymous branch with one `ShellHelper` definition;
`.public-header` in `shell.css`. Guards: the seam guard scans the viewer partials for session
accessors AND undeclared route helpers; the constant-identity guard; budgets for `public files#view`,
`explore#index` and `public users#show`; the phone sweep visits the public file page. Tests:
`public_file_view_test.rb`, `public_explore_test.rb`, `public_project_test.rb`, the budget file, the
template sweep (four viewer branches + the public file pages), `docs/invariants/files-preview.md`.

### S4-6 — a project can live anywhere

Files: `Projects::AdoptionsController#create` (a folder node → `maker_projects.folder_node_id`,
refusing `Projects/` itself, a folder already claimed, and the library root), the Files page
folder menu and Home, `app/views/projects/_form.html.erb` (status, make-current),
`ProjectsController#create` (flash names the path), `Maker::ProjectDiscovery` (stamp
`discovered_at`), `ProjectsController#show` (stamp `opened_at`), `_card.html.erb` (New badge),
`CurrentProjectController` (flash on every branch), one migration. Tests: `adoptions_test.rb`,
`project_discovery_test.rb`, `projects_test.rb`, `current_project_test.rb`.

### S4-7 — project kinds and panel choices

Files: `Maker::Project` (`kind`, `panels`, `KINDS`, `PANELS`), `Maker::ProjectKind.suggest(listing)`,
`app/views/projects/show.html.erb` (the loop), new `_panel_chooser.html.erb`, `_form.html.erb`
(kind), `_card.html.erb`, one migration. Tests: `project_kind_test.rb`, `project_page_test.rb`
(order and hiding), the query budget.

### S4-8 — connections and search

Files: `Maker::FileLink` + migration, writers in `tools/addons_controller.rb` (OpenSCAD output),
the Save-to-library door (S4-3), `Files::LinksController`, the file page's "Connected files" panel,
`SearchController` (notes, README text — bounded `LIKE` over `action_text_rich_texts` scoped by
user through the owning records), the orphan guard and reaper cases. Tests: `file_link_test.rb`,
`file_links_test.rb`, `search_test.rb`, `architecture_invariants_test.rb` (the new table's cases).
