# Stage 2 — the structure: a home, the project as the hub, and the maker surfaces the web never had

Date: 2026-09-04. Status: **proposed** — written at the end of stage 1 (the shell and design system,
PRs #307–#310) as the plan the user asked for; the decisions in §2 are the ones to confirm or flip
before the first stage 2 PR opens. Stage 1's spec is
`docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md`; this document is the
"phase 2" it deferred.

## 1. Why

Stage 1 gave every page one visual system and a shell that can carry more than five links. What it
did not touch is what the app is organised *around*, and three facts from the code say that is the
next problem:

- **`/` is a redirect to the file browser** (`config/routes.rb`), so the app opens on a folder
  listing. The current project — the one concept that ties Files, Tools and Projects together — is a
  select in the rail with no page of its own to land on.
- **A project's folder and a project's attachment list disagree about what the project contains.**
  Attaching a file is bookkeeping (`2026-07-26-file-organization-and-views-design.md` §1); the
  intake sweep files a project folder's loose files into `docs/`, `models/`, `photos/`; the project
  page lists attachments, not the folder. Two truths, one page.
- **Half the maker domain has models and a JSON API and no web page** (`tinkerex#126`, §12.9):
  inventory items with an immutable transaction ledger and a low-stock scope, BOMs whose lines point
  at exactly one of stock / a design file / free text, suppliers, locations, tags. A maker's working
  life (§1 of CLAUDE.md) is files *and* inventory *and* projects; the web app has one and a half.

## 2. Decisions (proposed; confirm or flip before PR S2-1)

1. **Home replaces the redirect.** `/` renders a Home page: the current project first, then what
   changed recently, then what needs attention. Sign-in lands there. Files keeps its place in the
   rail as the library. *Flip:* keep `/` → Files and make Home a sixth rail item; cheaper, but it
   leaves the app opening on a folder.
2. **The project page becomes the hub, and the folder becomes the truth of what a project holds.**
   Its Files panel lists the project's library folder (live nodes under `Projects/<slug>/`, grouped
   as today), with attachments from *elsewhere* in the library as a separate "Linked" group. Nothing
   moves on disk; the page stops disagreeing with the NAS.
3. **Inventory and BOM get a web UI, in that order.** Inventory first (stock is useful alone), then
   the BOM panel on the project page (a BOM is only useful with stock to point at). Suppliers and
   Locations arrive as settings pages, since they are reference lists.
4. **Items and Collections stay the desktop client's.** `Maker::Item` is the desktop app's catalog
   over the v1 API (its own header says so); the web's catalog is Models. Surfacing Items on the web
   would put two catalogs beside each other. *Flip:* if the desktop's Library tab is meant to appear
   on the web too, that is a separate spec.
5. **Tags become a web feature where they already exist in data**: models carry tags today;
   projects and inventory items gain them through the same polymorphic `Maker::Tag`. Tag chips
   filter each index; a tag page lists everything wearing it.
6. **Search grows from files to everything**, one results page grouped by kind, driven from the top
   bar the shell already has.
7. **A Settings hub** (`/settings`) collects the pages that are reference data and preferences:
   Shelves (exists), Suppliers, Locations, Tags, the account page, theme. The rail foot links it.
8. **Sharing (`tinkerex#120`) and selective sync (`tinkerex#121`) are out.** Both depend on the sync
   server; stage 2 stays inside this repo.

## 3. The slices, in order

Each slice is one spec-derived plan and one PR, green on all three backend legs, with every guard
mutation-checked, as stage 1 did. The order is chosen so each slice is useful alone.

| slice | PR | delivers | new tables |
|---|---|---|---|
| S2-1 | Home | `HomeController#index`, the Home page, `root` and sign-in landing, a sixth rail item, query-budget guard | none |
| S2-2 | Project hub | folder-as-truth Files panel with a Linked group; project stats from the folder | none |
| S2-3 | Inventory | `/inventory` index with low-stock, item page with ledger and an Adjust composer, Suppliers and Locations settings pages | none (all exist) |
| S2-4 | BOM | BOM panel on the project page (lines, rollup, consume-from-stock), BOM page | none |
| S2-5 | Tags and search | tag chips on models/projects/inventory, `/tags/:name`, `/search` grouped results | none (`maker_tags`, `maker_taggings` exist) |
| S2-6 | Settings hub | `/settings` with the reference pages and the account page moved under it | none |

No slice adds a table: stage 2 is web surfaces over data the app already keeps, which is what keeps
each PR reviewable and reversible.

## 4. S2-1: Home

### 4.1 What the page shows (top to bottom)

1. **The current project card**, or a "pick a project" prompt when none is current: name, the
   description at reading measure, the stats line PR 3 introduced, its open tasks (up to five,
   with the state mark), the latest build-log entry, and two actions: Upload (the same
   `projects/upload_control` the Files page uses) and Open.
2. **Continue**: three rows of tiles — recently updated projects (six, by `updated_at desc`, with
   covers through `Maker::Previews::ThumbnailMap`), recently changed files (eight live file nodes by
   `updated_at desc`, with thumbnails, the same `.grid-card` the Files grid uses), recently printed
   models (five `Maker::PrintRun`s by `printed_on desc`, each with its model and outcome).
3. **Attention**: failed prints in the last thirty days; once S2-3 lands, low-stock inventory items
   (the `low_stock` scope) — the section is built so S2-3 adds one row to it.
4. **Quick actions** in the page head: New project, Upload, Tools.

Everything reads columns that exist: `updated_at` on projects and nodes, `logged_at` on build-log
entries, `printed_on`/`outcome` on print runs, `status` on tasks. No counters, no new columns, no
activity table — the query-budget guard asserts constancy in N for the page.

### 4.2 Routing and landing

`root to: "home#index"`; `ApplicationController#after_sign_in_path_for` returns `root_path`. Two
tests pin today's landing: `test/system/support/web_helpers.rb#sign_in_as` asserts
`assert_current_path "/files"` (so every system test), and the Devise flow tests may assert the
redirect. Both change in the same PR to `/`. The Files page keeps `files_path`; the rail gets Home
as its first item (`rail_section` maps `home`), so six items.

### 4.3 Components it adds

- **`.home-hero`**: the current-project card, a `.panel` with the accent border the rail's card
  uses, so the two read as the same object.
- **`.tile-row`**: a horizontal, scroll-snapping row of tiles for the Continue section, with a
  heading and a "See all" link to the index it summarises.
- **`.attention-list`**: rows with a severity mark (danger for a failed print, accent for low stock),
  the object's name, one sentence, and one action.

### 4.4 Tests

Request: the page renders for a user with nothing (every section shows its empty sentence), with a
current project (the hero shows its tasks and latest entry), and with recents (tile counts and
order); `root` renders Home; sign-in lands on `/`; the query budget does not grow with projects,
files, runs or tasks. System: the hero's Upload posts through the same flow as Files; the tile rows
scroll rather than the page at 375px (extend the phone sweep).

## 5. S2-2: the project as the hub

The Files panel lists the project's folder: `Node` children of `Projects/<slug>/` (recursively, as
the intake sweep files them into `docs/`, `models/`, `photos/`), grouped by role as today, with the
attachment rows for nodes *outside* that folder in a "Linked" group. `@attachments` stays the source
of the file→project relation (detach, addon origin, cover); the folder listing is what the page
shows. The stats line counts the folder. Guards: `project_folder_intake_test.rb`'s ordering rules
(`docs/invariants/project-intake.md`) are untouched — the page reads, it never files.

## 6. S2-3: inventory

- **`/inventory`**: a `table.files`-vocabulary table (name, part number, category, quantity with
  unit, a low-stock badge when `quantity_cached <= min_quantity`, location, supplier), the Files
  toolbar (search on name/part number, category chips, a "low stock" chip, sort), and New item as
  the primary action. Every row links to the item page.
- **`/inventory/:id`**: the item's fields in the `dl.meta` strip, an **Adjust** composer (delta,
  reason from `InventoryTransaction::REASONS`, optional project, note) that posts through
  `InventoryTransaction.apply!` — the same door the v1 API uses, never a direct write to
  `quantity_cached` — and the ledger as a table (newest first, the balance after each row).
- **Settings → Suppliers, Locations**: list + inline add, like Shelves; Locations show their parent.
- Guards: the ledger's immutability (an edit form for a transaction must not exist), `release_bom_lines`
  on destroy (a BOM line pointing at a deleted item becomes free text — the model already does this;
  the page asserts the result), query budgets, the phone sweep.

## 7. S2-4: BOM

A **BOM panel** on the project page (below Tasks): lines with their target kind shown as a badge
(stock / design file / free text), quantity and unit, supplier; the rollup (`BomsController#rollup`'s
`resolved_target`) as totals; an Add-line composer whose target field is one of three inputs
(inventory item picker, file chooser via `shared/_folder_field`, free text) enforcing
`exactly_one_target` in the UI before the model does; **Consume** on a stock line posts a
`consumed` transaction against the project. A `/projects/:id/bom` page for the full list when it
outgrows the panel.

## 8. S2-5: tags and search

Tag chips on the models index (exists), the projects index and the inventory index, each filtering
by `?tag=`; a `/tags/:name` page listing every tagged object grouped by kind; a tag editor
(comma-separated, as models have) on project and inventory forms. `/search?q=` renders grouped
results — files (the existing flat search), projects, models, inventory — five per group with "See
all" links into each index's own search; the top bar's field posts here instead of to Files.

## 9. S2-6: settings

`/settings` lists Shelves, Suppliers, Locations, Tags, Account (the Devise edit page, which PR 1
already gave the card), Theme (the same three-way toggle as the rail). The rail foot's Sign out row
gains a Settings link. Nothing moves in the database.

## 10. What stays invariant across stage 2

- Every page is server-rendered Hotwire on `Maker::*` models with session auth (§14d); the v1 API
  is untouched and remains the desktop client's.
- No table is added; a stage 2 slice that needs one is a sign it belongs to a different spec.
- The design system's rules (`docs/invariants/design-system.md`) hold: tokens, layers, one
  definition per component, cookies not scripts, and the pinned class names.
- Query cost is asserted per page in `page_query_budget_test.rb`, constancy in N.
- The phone sweep in `test/system/shell_test.rb` gains every new page.
