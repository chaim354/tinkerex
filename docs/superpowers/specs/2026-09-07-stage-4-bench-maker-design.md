# Stage 4 — the bench maker's loop: stories-first UX for the project, its files and its page

**Date:** 2026-09-07 · **Status:** design; slices S4-1 … S4-8 · **Branch:** `claude/user-stories-ux-c52143`
**Stories:** `docs/user-stories.md` — the living document this spec is derived from and every slice
cites. **Plans:** `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` and one plan per slice.

## 1. Why

Stage 1 gave the web app a shell and a design system, stage 2 a structure, stage 3 a publishable
project. Every one of those specs justified itself from **code facts** ("three facts from the code
say"). None started from a maker. This stage does, and the first measurement of the real library
says the feature list and the use do not match:

| surface | real use on the share deployment, 2026-09-07 |
|---|---|
| library | 3,232 live files, updated the same day |
| box generator | 25 saved states, the last five days earlier |
| projects | 9, of which 8 auto-created from folders, all still `planning` |
| tasks, build log | 10 tasks and 3 entries in total, none since early August |
| print runs, inventory, BOM, releases, publishing, wiring, sheets | 0 each |
| notes | 1, in July |

The maker uses the app as a **viewer over the NAS** and as a **box generator**. The project layer
is built and unused. The stories were written to find out why, persona 1 only, across the six
themes the maker named: how a project comes to exist; each file type's round trip between a
desktop program, the share and the web; how files connect; staying organised with no bookkeeping;
publishing with documentation and the files embedded; and a project page that fits the project.

Fifty stories, each tagged against the code by a five-area audit and confirmed on a seeded library
shaped like the real one. Six `works`, twenty-six `rough`, sixteen `missing`. What the audit and the
walk turned up, in the order of how much of the real library each touches:

1. **All three real repos are project roots, and a root-repo project shows no README card, no
   Commits, no History** on its page — the card exists only for a repo *inside* the folder.
2. **Nothing the app records lives on the share.** Notes, tasks, log entries, box parameters,
   releases, tags and filing rules are database rows keyed by node ids a fresh install re-mints.
3. **MillMage and KiCad files file into `other/`,** a Gerber zip into `archives/`, while the pages
   for all three are among the best in the app.
4. **A README is never rendered on a private project page** unless it sits in a sub-folder repo, and
   cannot be edited on the web outside git. Publishing is the only way to see your own documentation.
5. **The public page has none of the viewers** — no 3D, no Measure, no Gerber — and `/explore` has no
   covers.
6. **Every project page is the same page.** Seven panels, fixed order, no hero, no pin, no type.

## 2. Decisions

**Settled**

1. **Stories first.** Every slice names, by id, the stories it closes or moves. A slice that moves
   no story is not in this stage. When a slice lands, its plan's close-out re-measures those tags
   in `docs/user-stories.md`; the ids never change.
2. **Persona 1 only.** The visitor appears only as the far end of persona 1's publishing stories.
   Personas 2–5 stay stubs until this stage has landed and the tags have moved.
3. **The record stays honest about use.** `built-unused` is a tag, not a verdict: a slice may
   move such a feature into the maker's path (S4-1 does this for photos and the README) but no
   slice adds depth to one.
4. **Out of this stage entirely:** the sync engine and desktop client, inventory, BOM, tasks,
   sharing between users, and anything that changes what the scan may observe (§14b).

**Proposed — flip before the slice that depends on each**

- **D1 Folders outside `Projects/`.** *Adopt in place.* A folder anywhere in the library can be
  made a project by one action; it keeps its path, and `folder_node_id` simply points there. No
  second kind of thing: one concept, and "the folder is the truth" survives untouched. Discovery
  stays what it is (direct children of `Projects/`, `docs/invariants/project-intake.md`); adoption
  is a door, not a sweep. (S4-6; stories 1.3, 4.7)
- **D2 Records beside the files.** *Deferred to its own spec, filed as open work.* Writing notes,
  the log, box parameters and releases onto the share would make a NAS self-describing and would
  survive a reinstall — and it changes what the scan may see, what a node id means across installs,
  and which paths every write guard reserves. That is a design, not a slice. In this stage "one
  place" means the **project page shows everything the project has** (S4-1) and story 4.6 stays
  `missing` with the deferral named.
- **D3 Editing outside git.** *Markdown is editable anywhere; other text stays git-only.* The
  git-editing rule (`docs/invariants/git-editing.md`) exists because a save on share or s3
  overwrites with no undo. For documentation the alternative today is no README at all — 0 of 9
  real projects have one the page shows — so the trade is named on the editor ("no history here;
  saving replaces the file") and chunk_remote keeps versions regardless. Code, `.scad` and every
  other text file keep the repository requirement. (S4-4; stories 5.3, 2.13)
- **D4 Project types.** *A `kind` plus per-project overrides.* `kind` (laser, print, cnc,
  electronics, mixed, other) is suggested from the folder's extension mix and editable; it presets
  panel order, panel visibility and the hero's preferred file type. A JSON `panels` column holds
  the maker's own show/hide/order overrides on top. (S4-7; stories 6.1–6.5)
- **D5 Public viewers.** *Bring the existing viewers to the public page as they are.* The 3D
  viewer, the Measure view (read-only), the Gerber stage and KiCanvas already fetch bytes from a
  URL; a public file page gives them the public blob route. (S4-5; story 5.5)

## 3. The persona

Charles at the bench: laser first (LightBurn, SVG, DXF, AI), 3D printing (STL, 3MF, STEP), CNC in
MillMage, electronics and firmware (three git repos, Gerbers, KiCad), saving from desktop programs
straight onto a NAS share the app indexes. The full portrait, with the file counts behind each
line, opens `docs/user-stories.md`.

## 4. Data

Small, and none of it before S4-2. No slice touches the sync server or the catalog's schema.

| slice | table / column | holds |
|---|---|---|
| S4-2 | `maker_projects.autofile` boolean, default true | per-project opt-out of the intake sweep |
| S4-2 | `maker_projects.last_swept_at`, `maker_projects.last_sweep_moves` integer | what the last sweep did, for the page to say so |
| S4-3 | `users.library_scanned_at` | when the last library scan finished, for an honest Rescan |
| S4-6 | `maker_projects.discovered_at`, `maker_projects.opened_at` | the "new" marker on an auto-created project |
| S4-7 | `maker_projects.kind` string, `maker_projects.panels` JSON | project type and panel overrides |
| S4-8 | `maker_file_links(user_id, from_node_id, to_node_id, kind, created_at)`, unique `(user, from, to, kind)` | file lineage: `derived_from`, `photo_of` |

Every column defaults to a value that reproduces today's behaviour, so a migration alone changes
nothing a maker sees.

## 5. The slices, in order

Each slice is one spec-derived plan and one PR, green on all three backend legs at identical run
counts, every guard mutation-checked, executed the way `.claude/commands/execute-plan.md` says.
The order is value to persona 1 first, cost second; S4-1 comes first because it is pure UI over
data the page already loads and every later slice builds on that page.

| slice | delivers | stories moved | tables |
|---|---|---|---|
| **S4-1 The project page shows what matters** | a **hero** from `cover_node_id` (image inline, else the server thumbnail); a **Photos** gallery on the private page, the public page's own logic reused; the **README card at the top of Files** for every project, and for a project whose root is a working tree the full repository card with Commits/History links and an honest caption; the six secondary panels **quiet when empty** — heading and one "Add …" control, no open composer, no zero-count groups; list-view rows carry the same context menu as tiles | 1.4, 2.9, 5.3 (render half), 6.1, 6.2, 6.3, 6.6, 6.8 | none |
| **S4-2 Filing that matches the bench** | roles for `.mage`, `.lbrn` and `.ai` (with `.ai` previewed through pdfium when its bytes are PDF); filing rules for `kicad_sch`/`kicad_pcb`; a zip the archive reader recognises as a board files into `pcb/`; `/settings/filing` regrouped as one card per folder; a per-project sweep opt-out; the sweep says what it did on the project page and in the eager flash; a display rule hiding `build/`, `node_modules/`, `__pycache__/` beside the dot-dirs, excluded from counts and search | 2.3, 2.4, 2.8, 4.1, 4.3, 4.8, 1.5 (filing half) | `autofile`, `last_swept_at`, `last_sweep_moves` |
| **S4-3 The round trip closes** | the file page shows the **library path** with copy; the file page **refreshes its own preview**; a browser Save re-enqueues the preview; Measure's SVG export and the print sheet gain **Save to library**, riding the existing two-door upload flow into the source file's folder; Rescan polls a real "scan finished" instead of guessing | 2.10, 2.11, 2.12, 2.13 (stale half) | `users.library_scanned_at` |
| **S4-4 Documentation on your own page** | a **Markdown editor** on the project page's README card for any project (D3), with a template when none exists and the no-history note on share/s3; a **Preview** of the public page for the owner at any visibility; a **Publish panel** on the project page — visibility with plain-language meanings, license, inline handle claim, the URL with copy, unlisted link copy and rotate; heading anchors kept through the sanitizer | 5.1, 5.2, 5.3, 5.4 (anchors), 5.8 | none |
| **S4-5 Visitors see what you see** | a public file page carrying the 3D viewer, Measure (read-only), Gerber, KiCanvas, images, PDF and code over the public blob route (D5); covers on public cards and `/explore`; a minimal public header with the site name and the author | 5.5, 5.7 | none |
| **S4-6 A project can live anywhere, and creation says what it did** | "Make this folder a project" on the Files page and Home (D1); the New project form gains status and "make current" (default on) and its flash names the folder; a **New** badge on auto-created projects until first open, and the Scan button's flash names what discovery created; "Not a project" as an explicit action distinct from Archive; a confirmation on every current-project switch | 1.1, 1.2, 1.3, 1.5, 1.6, 4.5, 4.7 | `discovered_at`, `opened_at` |
| **S4-7 Project kinds and panel choices** | `kind` suggested from the folder and editable (D4); presets for panel order and the hero's preferred type; per-project show/hide/reorder of panels; the cards show kind | 6.1, 6.2, 6.3, 6.4, 6.5 | `kind`, `panels` |
| **S4-8 Connections and search** | `maker_file_links` with `derived_from` written by the OpenSCAD tool and by Save-to-library, and set by hand on a file page ("This came from …"); `photo_of` from attaching a photo on a file page; both directions shown on the file pages; search over note bodies and README text | 3.2, 3.3, 3.4, 3.5 | `maker_file_links` |

Stories no slice moves, and why: 3.1 (works), 3.6 and 3.7 (out of scope: models and BOM), 4.2
(re-filing already-placed files is a move the sweep must not make on its own — stays `missing`,
noted in S4-2's plan), 4.4 (Home's per-project "new since" needs a per-project activity record —
S4-6 records `opened_at`, which is its first half), 4.6 (D2), 5.6 (a release with bytes is a
storage design), 6.7 (by design).

## 6. S4-1 in detail: the project page shows what matters

The plan is `docs/superpowers/plans/2026-09-07-stage-4-s1-project-page.md`. Zero schema; every
addition joins the page's one `PageNodes` union and one `ThumbnailMap`, so
`page_query_budget_test.rb` stays constant in N.

- **Hero.** Above the panels, when the project has a cover: an image-role cover renders inline
  through the blob route; any other cover renders its server thumbnail in a poll cell, the way the
  model page's hero poster does; no cover renders nothing (no placeholder box — the page is not a
  card). `Maker::Project#cover_node_id` already derives a cover from the attachments when none is
  chosen, so most real projects get one for free; the derived id joins the union so liveness is
  answered by `nodes.present`, never by the port.
- **Photos.** `Maker::ProjectPhotos.rows(listing:, entries:, page_nodes:)` is extracted from
  `Maker::PublicProject#photo_rows` and both pages call it; the private panel renders the same
  name-ordered, deduped grid with a `thumbs` poll and links to the private file pages. Omitted
  when there are none.
- **README card, for every project.** `Maker::ProjectFolderListing#root_repo?` answers whether the
  folder itself is a working tree (`.git` marker child of `folder_node_id` — the same check the
  walk already makes for every child dir, asked once of the root). When it is, `Maker::RepoCard`
  renders for a synthetic root `Dir` (loose files as its files, the tree as its children), at the
  top of the Files panel, with Commits/History links in the panel head, and the Loose caption
  reads "This folder is a git repository, so its files stay where they are." When it is not, the
  root README alone renders through `Maker::Readme.for` over the loose rows, same card styling,
  no commit facts. The folder's root node joins the batched `repo_roots` query, so the card costs
  no query of its own.
- **Quiet panels.** Build log, Tasks, Bill of materials, Wiring, Releases and Sheets each gain a
  `panel--quiet` state when empty: the heading and its one add control, nothing else — no "No
  entries yet.", no `Todo (0) / Doing (0) / Done (0)`. A populated panel renders exactly as today.
  Files is never quiet; its empty state already explains where the folder is.
- **List view.** `_file_rows.html.erb` emits `file_menu_data` on each row, so right-click offers
  the same Add note / Open / Download / Edit-in-tool the tile offers.

## 7. What stays invariant across stage 4

- **The folder is the truth.** Sections are subfolders; no display alias; nothing a slice adds
  renames or moves a folder the maker did not ask to move.
- **`Public::` never reads the session.** The owner's preview (S4-4) is a session-authed route in
  the private namespace rendering the public partials with a banner — never a bypass in
  `Public::BaseController`.
- **Bytes that land on the share go through the port.** Save-to-library (S4-3) and the README
  editor (S4-4) write through `Maker::Addons::LibraryOutput` or the existing upload doors — never
  a `File.write`, never a delete-then-create (§14a's `replace:` rule).
- **`ROLE_BY_EXT` stays the one file-type vocabulary** (`docs/invariants/files-preview.md`);
  filing rules may carry keys it cannot (KiCad), and a new extension's identity is still decided
  there first.
- **Discovery keeps its rules** (`docs/invariants/project-intake.md`); adoption in place is a
  door beside it, and it never mints `Projects/`.
- **Query cost is asserted, never assumed.** Every new panel or card joins the page's existing
  unions; `page_query_budget_test.rb`'s seeds grow with the new things (a cover, a photo per
  entry, a link per file) so a per-row read cannot hide.
- **The three backend legs report identical counts**, and every guard is mutation-checked with its
  output reported (§15).
- **Class names are a contract** (`docs/invariants/design-system.md`); a restyle never renames.
- **Stimulus controllers are derived from filenames** (§14d); a new `copy` controller (S4-3) or
  `panels` controller (S4-7) needs no test edit but must exist before any template names it.

## 8. Verification

- Per slice: `bin/ci` green; the three legs' run counts identical; the plan's mutation checks run
  with output reported; the close-out re-tags the slice's stories in `docs/user-stories.md`.
- Per stage: the six themes each have at least one story moved out of `missing`; the seeded
  library from this design (`test/fixtures/files` arranged as a laser repo project, a firmware +
  PCB project, a 3D-print project, and folders outside `Projects/`) is the fixture every slice's
  system test screenshots; the real library is re-probed (read-only, aggregate) after S4-4 lands to
  see whether a README, a photo and a published project exist where none did.

## 9. Out of scope, named so it is not re-derived

- Records beside the files (D2) — own spec; filed as open work in the record.
- Releases that carry bytes (5.6) — a storage design, not a page.
- Per-project filing rules (4.3's deeper half) — a resolution order across two maps; revisit after
  S4-2's grouped page shows whether one map is still too many.
- Re-filing already-placed files on a rule change (4.2) — a move the sweep must not make unasked.
- Anything on the desktop client's side of the wire, including "reveal on the share" from the
  browser — S4-3 shows the path and copies it; opening a local program is the OS's job.
