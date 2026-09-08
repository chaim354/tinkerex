# Stage 4, S4-7: project kinds and panel choices — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S4-7 of `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (§5's S4-7 row, decision **D4**). A project gains a **`kind`** — laser, print, cnc, electronics, mixed, other — **suggested from what its folder actually holds** and editable on the edit form. The kind **presets** which panels the project page renders, in what order, and which role the hero prefers. A **`panels` JSON column** holds the maker's own show/hide/reorder on top, chosen with **no JavaScript** from a chooser at the bottom of the page it is about. The **public page honours the same layout**. The cards show a kind, and `/projects?kind=` filters by one. The seven hard-coded `render` calls in `show.html.erb` become **one loop over a list**.

**Stories moved:** 6.1, 6.2, 6.3, 6.4, 6.5.

**Architecture:** `Maker::Project::PANELS` is the canonical panel-key list and the only thing the loop may be handed — the chooser renders from it and `Projects::PanelsController` intersects every write with it, so `render "projects/#{key}"` can never be given a partial name that does not exist. `Maker::ProjectKind` holds the presets, the labels, the hero-role preference and `.suggest`, a pure function over `Maker::ProjectFolderListing#all_rows`' roles plus `#root_repo?`. `Maker::ProjectKind.layout_for(kind:, overrides:)` merges preset ← overrides into a `Layout` (`order`, `hidden`) and is **total and defensive at read time**: an unknown key in the column is filtered out rather than raising on the maker's own page. `Maker::Project#panel_layout` is what `ProjectsController#show`, the chooser and `Maker::PublicProject` all read, so private and public cannot disagree about what is hidden. Three panels' controller loads (`bom`, `wiring`, `releases`) are skipped when hidden, and the three that are **not** skipped each have a named reader outside their panel.

**Tech Stack:** Rails 8, Hotwire (**no new Stimulus controller and no new JS** — see amendment 3), Minitest, one migration, `page_query_budget_test.rb`, `template_hygiene_test.rb`, `css_hygiene_test.rb`, `schema_map_test.rb`.

---

## Amendments — decisions taken while writing this plan. These override the prompt and the spec where they differ; when a step below conflicts with one, the amendment wins.

1. **`kind` defaults to `other`, and `other`'s preset is EXACTLY today's page.** Spec §4's rule is
   "every column defaults to a value that reproduces today's behaviour, so a migration alone changes
   nothing a maker sees". `PRESETS["other"]` therefore hides nothing and reorders nothing, and
   `Maker::ProjectKind.hero_roles("other")` is `%w[image model]` — which is `derived_cover_node_id`'s
   existing `find image || find model || first` spelled as data. Every project that exists on the
   three live deployments keeps the page it has. Only a project created **after** this migration, by
   discovery or adoption, gets a suggested kind and therefore a preset.

2. **`schematics` is in NO kind's hidden set, and that is an argument rather than an omission.**
   `projects/_schematics.html.erb` renders nothing when the folder holds no KiCad file, so hiding it
   for laser/print/cnc has no observable effect **except** in the one case where it is wrong — a
   laser project that does hold a `.kicad_pcb`. A default that can only ever be invisible or wrong is
   not a default worth having. The same argument protects `photos`, which is why it is in `ALWAYS`
   below rather than in a hidden set.

3. **THE CHOOSER USES NO JAVASCRIPT AND NO STIMULUS CONTROLLER, so `app/javascript/controllers/panels_controller.js` IS NOT CREATED.**
   Spec §7 anticipates "a `panels` controller (S4-7)". It is not needed: Show/Hide is one form of
   checkboxes with a Save, and Up/Down are one `button_to` each. §14d's rule is that a
   `data-controller` name resolving to nothing is a **silent no-op**, so the safe direction is to
   name no controller at all — which is what this plan does. `stimulus_hygiene_test.rb` needs no
   edit; do not add one, and do not write `data-controller="panels"` anywhere.

4. **The chooser lives at the BOTTOM OF THE PROJECT PAGE, in a `<details>` closed by default, not on the edit form.**
   Two reasons, and the second is the deciding one. (a) Reordering is a repeated action whose result
   you have to see; on the edit form each click would redirect back to a form that shows a list, not
   a page. On the project page each click re-renders the page **with the panels in their new order**.
   (b) `template_hygiene_test.rb` already sweeps "project detail", so the new partial is covered with
   no new entry in its `pages` map. It stays closed and below `.project-panels`, so S4-4's decision 8
   — a settings box must not displace the maker's own content — is honoured.

5. **A move and a Save are two shapes on ONE `PATCH`, and Reset is a `DELETE`.** `resource :panels`
   (singular) gives `PATCH/DELETE /projects/:id/panels`. `Projects::PanelsController#update` branches
   on `params[:move]` first; only the other branch calls `params.require(:panels)`, so a move request
   cannot 400 on a missing key. Reset is `#destroy` writing `panels: nil`, because "reset" means
   *remove the override*, not *write today's preset into the column* — the second would freeze this
   release's preset onto the row forever and stop the project tracking its own kind.

6. **The re-open hint rides in the URL, exactly as `?scanning=1` does.** After any write the door
   redirects to `project_path(@project, panels: "open", anchor: "panels")` and `#show` sets
   `@panels_open = params[:panels] == "open"`. Without it every click closes the `<details>` and the
   maker has to reopen it to click again. It is a one-shot render hint, not state, which is why it
   rides in the URL — the argument `ProjectsController#show` already makes for `@scan_started`.

7. **A kind is suggested ONCE, at creation, and never re-derived.** Re-suggesting on every scan would
   silently rearrange a page the maker may have arranged themselves, and there is no way for the page
   to tell "the preset moved" from "I moved it". The edit form is the one place a kind changes after
   creation. A folder created empty and filled later stays `other`, which is the honest answer:
   nothing was there to read.

8. **S4-7 DOES NOT DEPEND ON S4-6, and Task B checks rather than assumes.** `Maker::ProjectDiscovery`
   is on `main` today and Task B wires the suggestion into it. `Projects::AdoptionsController` is
   S4-6's and may or may not exist when you start: **`ls app/controllers/projects/adoptions_controller.rb`**.
   If it is there, Task B adds one `kind:` line and one test to it; if it is not, Task F records the
   obligation in the overview's S4-6 territory section. Do not create that controller here.

9. **S4-4 IS A SOFT PREREQUISITE, and Task A step 1 decides which way this lands.**
   `PANELS` must enumerate **every** panel the page renders, or the maker sees a panel the chooser
   cannot list — the one-question-two-answers shape §14a keeps recording. **`ls app/views/projects/_publish.html.erb`.**
   Present (S4-4 merged) → `PANELS` ends `sheets publish`, `ALWAYS` is `attachments photos publish`,
   `PANEL_LABELS` carries "Publish", and `show.html.erb` loses S4-4's trailing `render "publish"` to
   the loop. Absent → drop `publish` from all three, and Task F writes into the overview's S4-4
   territory section that S4-4 must add it to `PANELS`/`PANEL_LABELS`/`ALWAYS` and render it
   **through the loop**, never as a tenth `render` under it.

10. **`attachments`, `photos` and `publish` are unhideable, and `LEAD` is a different question from `ALWAYS`.**
    `ALWAYS = %w[attachments photos publish]` is *what may not be hidden*: Files is the folder, which
    is the truth (spec §7); Photos already omits itself when empty, so hiding it buys nothing and can
    only surprise; Publish is the target of the page head's `#publish` anchor (S4-4), and a dead
    anchor is worse than a panel nobody wanted. `LEAD = %w[attachments photos]` is *what opens every
    project page whatever its kind* — the two agree on two members by coincidence, not by identity,
    which is the same warning `scannable`/`port_writable`/`dir_deletable` carry in §14a. Spell both.

11. **Only `bom`, `wiring` and `releases` skip their controller loads.** `@tasks` and `@sheets` are
    read by the **stats line** in `show.html.erb` (`done of N tasks`, `N sheets`) and `@entries` is
    read by **`Maker::ProjectPhotos`** through `entry_photo_ids`, so skipping any of the three would
    change a surface other than its own panel — which is exactly the condition the prompt puts on the
    skip. `@bom_lines` does feed `@page_nodes`, but only so that `projects/_bom_lines` can resolve a
    file line's node; nothing else reads a BOM node id off that union, so emptying it is safe.
    Stated as a table in Task C step 3, and pinned by a query-count test in Task E.

12. **No index on either column, and the reason is measured against how the page reads them.**
    `panels` is never a predicate — it is read off a row the page already loaded. `kind` is a
    predicate on exactly one page, `/projects?kind=`, which already materialises **every** one of the
    user's projects (`scope.order(updated_at: :desc).to_a`) and partitions them in Ruby, so an index
    would buy nothing a `WHERE` over an already-loaded set does not. A `(user_id, kind)` index would
    also be a fourth btree write per project row and would sit one step from
    `architecture_invariants_test.rb`'s prefix guard, beside the three existing `user_id`-led indexes.
    `tenant_cleanup_test.rb` and `structural_orphan_test.rb` both derive their case lists from the
    schema and neither column is a `user_id` or a structural edge — **verify, expect no edit**.
    `schema_map_test.rb` needs `bin/rails schema:map` and the regenerated page committed.

13. **The suggestion reads the catalog, never the port**, so `Maker::ProjectDiscovery`'s own header
    claim ("it never touches the port… identical on all three backends and testable without a library
    on disk") survives and is **extended in the same commit** rather than left false: the sweep now
    also *reads* `nodes` to suggest a kind. Cost: one shared `Maker::LibraryTree` for the whole run
    plus **two queries per project created** — at the `MAX_PROJECTS` cap, 100 queries in a background
    job's first run and zero in the steady state, where `created` is 0.

---

## Decisions on the open questions (orchestrator review, 2026-09-07) — these override the text below

1. **`sheets` hidden by default for laser, print and electronics stands**, on the zero-use evidence.
   One-word edit in `PRESETS` if a maker asks; not mid-task.
2. **Calibrate `REPO_WEIGHT` and `MIXED_SHARE` against the real library before the PR opens.** At
   close-out, run a READ-ONLY, self-contained probe on the share deployment (the box does not carry
   this slice's code, so the script brings its own extension→family map and the same arithmetic) over
   the nine real projects' folders, printing the family counts and the suggested kind for each,
   writing nothing. If an answer is plainly wrong for a project the owner knows (a laser project
   read as `print`), adjust the constants and their table rows before `gh pr create`, and put the
   nine answers in the PR body.
3. **The chooser stays on the project page**, a closed `<details>` below the panels, as planned.
4. **The unique index is S4-6's open item**, not this slice's.
5. **Nothing re-suggests a kind after creation.** A later "this folder looks like a laser project —
   switch?" is a prompt, never a write; record that in the stories row for 6.5.
6. **The migration task also runs `bin/rails schema:map` and commits `docs/schema-map.html`** —
   `test/schema_map_test.rb` fails the full gate otherwise, and no per-task run reaches it (S4-2's gate).
7. **Order of landing is S4-3, S4-4, S4-5, S4-6, then this slice**, so S4-6's adoption door and
   S4-4's `_publish` panel WILL exist; the conditional hand-off steps in Task F are for a changed
   order only.

When a step below conflicts with a decision here, the decision wins.

## Before you start

- Branch from `main` at `7b2ae83` (S4-1 through S4-6 all merged; nothing else is in flight in this worktree). Never push to `main`. **Both conditional prerequisites resolve to PRESENT**: `app/views/projects/_publish.html.erb` exists (S4-4, amendment 9's first branch — `PANELS` ends `sheets publish`, `show.html.erb` renders it through the loop) and `app/controllers/projects/adoptions_controller.rb` exists (S4-6, amendment 8 — Task B adds its `kind:` line and test there). S4-6 also made `Project#ensure_library_folder!` mint only when `folder_node_id` is nil, added `discovered_at`/`opened_at`, `autofile: false` on adopted projects, and a status select + `make_current` on the form — read today's `projects_controller.rb`, `_form.html.erb`, `_card.html.erb` and `show.html.erb` before editing them. Line numbers quoted below were measured before S4-2…S4-6 landed and have drifted; anchor every edit on the quoted TEXT. Subagents in this stage run on Opus.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one
  full-suite run at a time; from a worktree
  `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`. The three backend
  legs (`test`, `test-s3`, `test-chunk-remote`) must report identical run counts.
- **Read first:** `docs/invariants/design-system.md` rules 3 (a component selector is defined in
  `components.css` and nowhere else — everything this slice adds is a page modifier in
  `pages/projects.css`, and the kind badge reuses `.badge` and adds **no** rule for it), 11 (no page
  scrolls sideways at 375px — the chooser is a row of ten panels with three controls each) and 12
  (class names are a contract). Then CLAUDE.md **§14d**: the `form_with` `scope:` rule and *assert
  the rendered field name*; an ERB comment ends at its first `%>`, so never write `%>` inside
  `<%#` — describe the wrong spelling in words; a `data-controller` that resolves to nothing is a
  silent no-op (amendment 3); `Public::` stands on `ActionController::Base` and never reads the
  session. Then **§14e**'s query-cost bullet (assert **constancy in N**, never a literal — the
  counts differ per `LIBRARY_BACKEND`). Then `docs/invariants/project-intake.md`, but **only** for
  what a discovered project's creation looks like: "THE CLAIM LOOKUP IS UNSCOPED — the row is the
  memory", and that `Maker::ProjectDiscovery` never mints `Projects/` and never calls
  `ensure_library_folder!`. This slice adds no rule there.
- **Facts verified by reading, that you will rely on:**
  - `app/views/projects/show.html.erb:76-97` renders **nine** panels today in this order:
    `attachments`, `photos`, `schematics`, `build_log`, `tasks`, `bom`, `wiring`, `releases`,
    `sheets`. S4-4 appends `publish` as a tenth, last (its Task E step 9(b)).
  - Three of them take **locals, not ivars**, and their header comments say why (the public page
    renders the same partial): `_wiring` takes `project:`/`connections:`/`editable:`
    (`_wiring.html.erb:8-14`), `_releases` takes `project:`/`releases:`/`current_tokens:`/`repos:`/
    `editable:` (`_releases.html.erb:9-21`), and S4-4's `_publish` takes `project:`. The other six
    read ivars. **Do not convert either group** — the loop carries a per-key locals map instead.
  - `Maker::ProjectFolderListing::Row#role` is `Maker::FileAttachment.role_for(node.name)`
    (`project_folder_listing.rb:51`), pure and current, never a stored column. `#all_rows` is
    "THE ONE PLACE THAT KNOWS THE FULL SET" (`:153-160`) and is bounded by `FILE_CAP = 300`.
  - `#root_repo?` is in memory, no query (`project_folder_listing.rb:131-133`), and answers false
    when the folder is not available.
  - `Maker::FileAttachment::ROLES` has **thirteen** members (`file_attachment.rb:12-37`):
    `model image instructions document vector laser cad_source code gcode cnc_design pcb
    source_archive other`. `cnc_design` is `.mage` and `laser` is `.lbrn`/`.lbrn2` — both landed with
    S4-2, so a MillMage or LightBurn v1 file now carries a role the suggestion can read.
  - `Maker::ProjectFolderListing.new(user, project, tree:)` reads **exactly one attribute** of the
    project it is given, `project.folder_node_id.presence` (`:99`). That is what lets the suggestion
    run against an **unsaved** `Maker::Project.new(folder_node_id:)` and be part of the `create!`
    rather than an `update_column` after it — one write, and a project is never momentarily `other`.
  - `Maker::LibraryTree.new(user)` is ONE pluck of the user's dirs (`library_tree.rb:13-18`), and
    `ProjectFolderListing` accepts it through `tree:` so a sweep pays it once.
  - `maker_projects` already carries four indexes, three of them led by `user_id`
    (`db/schema.rb:333-336`). `maker_addon_states.data` is `t.json … default: {}, null: false`
    (`:78`) and `maker_sheets.data` is a plain nullable `t.json` (`:382`) — both run on SQLite and
    Postgres, so `t.json` is settled here.
  - The schema is at `version: 2026_09_07_120100`; S4-2 took `20260907120000`/`20260907120100` and
    S4-6 plans `20260907140000`. **This slice takes `20260907160000`**, which runs forward on a
    database that already has any of them. Migrations here declare `ActiveRecord::Migration[8.1]`.
  - `ShellHelper::SECTIONS` maps `controller_path`'s **first** segment (`shell_helper.rb:11-22,80-83`).
    `projects/panels` resolves to `projects`, so **no `SECTIONS` entry is needed and none must be
    added** — the rail still lights Projects.
  - `projects/_wiring.html.erb:16-20` is this repo's precedent for the HTML `form=` attribute
    ("A `<form>` CANNOT SPAN TABLE CELLS, so each row's `<form>` sits OUTSIDE the table … and every
    field plus the row's Save button point back at it by id"). The chooser uses the identical idiom
    for the identical reason: a `<form>` cannot contain a `button_to`'s own form.
  - `button_to ... params:` builds hidden inputs **without** the form builder (§14d), so a move
    button needs no `scope:` and cannot hit the blank-`object_name` trap.
  - `template_hygiene_test.rb`'s coverage assertion is **per TEMPLATE** and derived from the tree
    (`:445-451`): a new partial that no page in `pages` renders fails it. "project detail" is already
    in that map (`:316`), so the chooser is covered by amendment 4's placement.
  - `test/system/shell_test.rb`'s phone sweep visits `project_path(project)` and already opens two
    things behind a boolean flag asserted after the loop (`launched_gerber`, `opened_repo`,
    `:268-309`) — that file's own rule for a branch gated on a path match.
  - `page_query_budget_test.rb#count_queries` (`:46-56`) and `#assert_constant_queries` (`:59-71`)
    are the file's own instruments; the `projects#show` seed already grows repos, entry photos,
    folder images, BOM lines of three kinds, connections and releases with N.
- Fixtures are **port-free**. A project folder in a request test is `project_folder_rows!(user, project)`
  (`test/test_helper.rb:171-179`) — never `ensure_library_folder!` (a real mkdir; red on s3 and
  chunk_remote). Nodes are `user.nodes.create!(node_id:, name:, kind:, parent_node_id:, size:, mtime:)`.
  There is **no shared `sign_in`**: copy the body verbatim from the suite you are editing
  (`projects_flow_test.rb:23-28`, `project_page_test.rb:11-15`).
- `git add` a new file before a mutation check; restore with `git checkout -- <file>`; clear
  `tmp/cache/bootsnap*` after an equal-length restore; `git status --porcelain` before the next run.

## The presets, tabulated

`order` is derived, never spelled out: `(LEAD + first + PANELS) & PANELS`. Only `electronics`
supplies a `first`, and `LEAD` is what keeps Files and Photos at the top of every kind's page.

| kind | label | `first` (lifted after LEAD) | `hidden` by default | hero roles, in order |
|---|---|---|---|---|
| `laser` | Laser cutting | — | `bom` `wiring` `releases` `sheets` | `image` `model` |
| `print` | 3D printing | — | `wiring` `releases` `sheets` | `model` `image` |
| `cnc` | CNC | — | `bom` `wiring` `releases` | `image` `model` |
| `electronics` | Electronics & firmware | `schematics` `wiring` | `sheets` | `pcb` `image` `model` |
| `mixed` | Mixed | — | — | `image` `model` |
| `other` | Other | — | — | `image` `model` |

Why each hidden set is what it is, in one line apiece: **laser** is story 6.1 verbatim ("not BOM,
wiring and releases") plus `sheets`, which real use puts at zero across nine projects and which
story 6.1 does not name among what should be first; **print** keeps `bom` because a printed assembly
is printed parts plus hardware, and drops the same three; **cnc** drops `bom` because a milled part
is one billet, and keeps `sheets` because feeds, speeds and a job sheet are the CNC bench's
paperwork; **electronics** is story 6.2 verbatim ("README, board, schematic, commits and wiring at
the top") — the README and Commits are already at the top of Files since S4-1, and `first` lifts
Schematics and Wiring above the build log; **mixed** and **other** hide nothing, and `other` is the
migration default, which is amendment 1.

`hero_roles("other") == %w[image model]` reproduces `derived_cover_node_id`'s existing
`find image || find model || first` exactly. The derivation reads the **relation**
(`file_attachments`), not the folder listing, and must keep doing so — the column's own comment
(`project.rb:106-111`) forbids a liveness or folder query there because `#cover_node_id` is called
once per card on the index. A discovered project's files **are** attachments (`Maker::ProjectIntake`
attaches everything it finds), so the preference has real material to choose from.

## File structure

| path | responsibility | task |
|---|---|---|
| new `db/migrate/20260907160000_add_kind_and_panels_to_maker_projects.rb`, `db/schema.rb`, `docs/schema-map.html`, `app/models/maker/project.rb` (`KINDS`, `PANELS`, `PANEL_LABELS`, the validation, `#panel_layout`, `#visible_panels`, `#derived_cover_node_id`), new `app/services/maker/project_kind.rb`; new `test/services/maker/project_kind_test.rb`, `test/models/maker/project_test.rb`, `test/schema_map_test.rb` (regenerate), `test/models/tenant_cleanup_test.rb` + `test/models/structural_orphan_test.rb` (verify, expect no edit) | the columns, the vocabulary, the presets and the suggestion | **A** |
| `app/services/maker/project_discovery.rb`, conditionally `app/controllers/projects/adoptions_controller.rb`; `test/services/maker/project_discovery_test.rb`, conditionally `test/integration/web/project_adoptions_test.rb` | who writes the suggested kind | **B** |
| `app/controllers/projects_controller.rb` (`#show`, `#index`, `#project_params`), `app/views/projects/show.html.erb`, new `app/views/projects/_panel_chooser.html.erb`, new `app/controllers/projects/panels_controller.rb`, `config/routes.rb`, `app/assets/stylesheets/pages/projects.css`; `test/integration/web/project_page_test.rb`, new `test/integration/web/project_panels_test.rb` | the loop, the chooser and the door | **C** |
| `app/views/projects/_form.html.erb`, `_card.html.erb`, `index.html.erb`, `app/views/home/_project_hero.html.erb`, `app/services/maker/public_project.rb`, `app/views/public/projects/_page.html.erb` (or `show.html.erb` — re-anchor); `test/integration/web/projects_flow_test.rb`, `test/integration/web/home_test.rb`, `test/integration/web/public_project_test.rb` | the form, the cards, the filter and the visitor | **D** |
| `test/integration/web/page_query_budget_test.rb`, `test/integration/web/template_hygiene_test.rb`, `test/system/shell_test.rb`, `test/css_hygiene_test.rb` | the cross-cutting guards | **E** |
| `docs/user-stories.md` (re-tag 6.1–6.5 and the Coverage counts), `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` (the S4-7 row, the quiet-panel contract's other half, and amendments 8/9's obligations) | close-out | **F** |

**Dependencies and batches.**

1. **A alone** — everything else reads `Maker::Project::PANELS` or `Maker::ProjectKind`.
2. **B and C in parallel** — disjoint file sets, disjoint test files.
3. **D** — needs C's `@kind`/`@project_kinds` and C's `project_params` permitting `:kind`.
4. **E** — its four files are single files that C and D would otherwise both touch; keeping them
   here is what makes C and D parallelisable at all (memory: `parallel-agents-one-worktree-rules`).
5. **F** last: its re-tags cite what the four tasks above actually landed.

---

### Task A: the two columns, the vocabulary, the presets and the suggestion

**Files:**
- Create: `db/migrate/20260907160000_add_kind_and_panels_to_maker_projects.rb`, `app/services/maker/project_kind.rb`
- Modify: `db/schema.rb` (generated), `docs/schema-map.html` (generated), `app/models/maker/project.rb`
- Test: new `test/services/maker/project_kind_test.rb`, `test/models/maker/project_test.rb`; verify `test/schema_map_test.rb`, `test/models/tenant_cleanup_test.rb`, `test/models/structural_orphan_test.rb`

- [ ] **Step 1: decide the `publish` question (amendment 9) and record it.** Run
      `ls app/views/projects/_publish.html.erb`. Write the answer into the commit message at step 12
      and hand it to Task C step 4 and Task F step 3. Everything below is written for the
      **present** case; where it is absent, drop `publish` from `PANELS`, `PANEL_LABELS` and
      `ALWAYS`, and drop `publish` from the `assert_equal` in step 6's totality test.

- [ ] **Step 2: the migration.**

```ruby
# THE PROJECT'S TYPE AND ITS PAGE'S LAYOUT (stage 4, S4-7; decision D4; stories 6.1-6.5).
#
# BOTH DEFAULTS REPRODUCE TODAY'S PAGE, which is stage 4's own rule (spec §4): `kind` is "other",
# whose preset hides nothing and reorders nothing, and `panels` is NULL, which Maker::ProjectKind
# reads as "no overrides". Running this migration on the three live deployments changes what
# nobody sees. Only a project created AFTER it — by Maker::ProjectDiscovery or by S4-6's adoption
# door — gets a suggested kind, and therefore a preset.
#
# NO INDEX ON EITHER, DELIBERATELY. `panels` is never a predicate: it is read off a row the page
# already loaded. `kind` is a predicate on exactly one page, /projects?kind=, which already
# materialises every one of the user's projects (`scope.order(updated_at: :desc).to_a`) and
# partitions them in Ruby — so an index buys nothing a WHERE over an already-loaded set does not,
# while costing a fourth btree write per project row beside the three `user_id`-led indexes this
# table already carries. It would also sit one step from architecture_invariants_test.rb's
# strict-prefix guard.
#
# `panels` IS NULLABLE RATHER THAN `default: {}`, for the reason `cover_node_id`'s own comment
# gives: nullable means "nobody has chosen", which is what every existing row means, and it keeps
# the forward run a pure DDL with no backfill. `Maker::ProjectKind.layout_for` reads nil and {}
# identically, so nothing downstream branches on which one it gets.
#
# `t.json` RUNS ON BOTH ADAPTERS — maker_addon_states.data and maker_sheets.data are already json
# on SQLite (self-host) and Postgres (managed), so this needs no adapter branch (§14e).
class AddKindAndPanelsToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_projects, :kind, :string, null: false, default: "other"
    add_column :maker_projects, :panels, :json
  end
end
```

- [ ] **Step 3: migrate dev and test, and commit the generated schema.**

```bash
bin/rails db:migrate
RAILS_ENV=test bin/rails db:migrate
bin/rails schema:map
git diff --stat db/schema.rb docs/schema-map.html
```
`db/schema.rb`'s version line must read `2026_09_07_160000` and `maker_projects` must gain
`t.string "kind", default: "other", null: false` and `t.json "panels"` — both in the dump's
alphabetical column order, so `kind` lands after `folder_node_id` and `panels` after `name`.

- [ ] **Step 4: the failing service test.** Create `test/services/maker/project_kind_test.rb`:

```ruby
require "test_helper"

module Maker
  # STAGE 4, S4-7 (decision D4): what a project's folder says it is, and what that presets.
  #
  # THE SUGGESTION IS A PURE FUNCTION over Maker::ProjectFolderListing — roles from filenames
  # (Row#role) plus one boolean (#root_repo?) — so it is table-driven here rather than probed
  # through a sweep, and it needs no library on disk and no port on any of the three legs.
  class ProjectKindTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pk-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Sample")
      @folder = project_folder_rows!(@user, @project)
    end

    def file(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: "n-#{SecureRandom.hex(4)}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1, size: 1)
    end

    def dir(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: "d-#{SecureRandom.hex(4)}", name:, kind: "dir",
                          parent_node_id: parent, mtime: 1, size: 0)
    end

    def suggest = Maker::ProjectKind.suggest(Maker::ProjectFolderListing.new(@user, @project))

    # THE TABLE. Each row is a folder shaped like one on the bench, and the expected kind is what
    # the page it presets has to be right about. `mixed` is what a SECOND strong family means, and
    # "strong" is measured against the leader rather than against the folder's total, so a project
    # with forty photos and two SVGs is still a laser project.
    CASES = {
      "a LightBurn folder is laser" => [ %w[box.lbrn2 lid.lbrn panel.svg tray.dxf shot.png notes.md], "laser" ],
      "meshes and CAD are print"    => [ %w[base.stl shade.3mf clip.step body.f3d readme.md], "print" ],
      "toolpaths and MillMage are cnc" => [ %w[pocket.nc roughing.gcode job.mage stock.png], "cnc" ],
      "sources and Gerbers are electronics" => [ %w[main.c board.gtl board.drl config.yml], "electronics" ],
      "two strong families are mixed" => [ %w[panel.svg lid.svg cut.dxf base.stl body.step clip.stl], "mixed" ],
      "photos and documents alone are other" => [ %w[shot.png plan.pdf notes.md bolts.csv], "other" ],
      "an empty folder is other" => [ [], "other" ]
    }.freeze

    CASES.each do |name, (names, expected)|
      test "suggest: #{name}" do
        names.each { |n| file(n) }
        assert_equal expected, suggest
      end
    end

    # THE WORKING TREE IS EVIDENCE, NOT A VERDICT. All three real repositories on the share
    # deployment are firmware, so a `.git` at the folder root counts toward electronics — but only
    # REPO_WEIGHT worth, so a laser project someone keeps in git is still a laser project.
    test "a bare working tree with nothing recognisable in it reads as electronics" do
      file("README.md")
      dir(Library::RepoMetadata::DIR_NAME)

      assert_equal "electronics", suggest
    end

    test "a working tree full of laser files is still laser" do
      %w[box.lbrn2 lid.lbrn panel.svg tray.dxf cut.svg].each { |n| file(n) }
      dir(Library::RepoMetadata::DIR_NAME)

      assert_equal "laser", suggest
    end

    test "a project with no live folder suggests other rather than raising" do
      orphan = @user.maker_projects.create!(name: "Folderless")

      assert_equal "other", Maker::ProjectKind.suggest(Maker::ProjectFolderListing.new(@user, orphan))
    end

    # THE DOOR EVERY WRITER USES, and the reason it exists: it can be asked about a folder before
    # the project row exists, so `kind:` is part of the create! rather than an update_column after
    # it (Maker::ProjectDiscovery, S4-6's adoption).
    test "suggest_for answers for a folder node with no project row at all" do
      %w[base.stl body.step clip.stl].each { |n| file(n) }

      assert_equal "print", Maker::ProjectKind.suggest_for(user: @user, folder_node_id: @folder.node_id)
      assert_equal "other", Maker::ProjectKind.suggest_for(user: @user, folder_node_id: nil)
    end

    # --- the presets --------------------------------------------------------------------------

    # TOTALITY, the shape project_folders_test.rb's "every role has a folder" already has: a kind
    # with no preset would fall back to `other`'s silently, and a preset naming a panel that does
    # not exist is a MissingPartial on the maker's own page.
    test "every kind has a preset, and every key in every preset is a real panel" do
      assert_equal Maker::Project::KINDS.to_set, Maker::ProjectKind::PRESETS.keys.to_set
      assert_equal Maker::Project::KINDS.to_set, Maker::ProjectKind::LABELS.keys.to_set
      assert_equal Maker::Project::PANELS.to_set, Maker::Project::PANEL_LABELS.keys.to_set

      panels = Maker::Project::PANELS.to_set
      Maker::ProjectKind::PRESETS.each do |kind, preset|
        assert_operator panels, :superset?, preset[:first].to_set,  "#{kind}: unknown key in first"
        assert_operator panels, :superset?, preset[:hidden].to_set, "#{kind}: unknown key in hidden"
        assert_empty preset[:hidden] & Maker::ProjectKind::ALWAYS, "#{kind} hides an always-shown panel"
      end
    end

    test "every kind's order is a permutation of PANELS, and every kind opens with Files then Photos" do
      Maker::Project::KINDS.each do |kind|
        order = Maker::ProjectKind.layout_for(kind:, overrides: nil).order
        assert_equal Maker::Project::PANELS.sort, order.sort, "#{kind} drops or invents a panel"
        assert_equal Maker::ProjectKind::LEAD, order.first(Maker::ProjectKind::LEAD.size), "#{kind}"
      end
    end

    test "other reproduces today's page exactly" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: nil)

      assert_equal Maker::Project::PANELS, layout.order
      assert_equal [], layout.hidden
      assert_equal Maker::Project::PANELS, layout.visible
    end

    test "laser hides the three story 6.1 names, and electronics lifts schematics and wiring" do
      laser = Maker::ProjectKind.layout_for(kind: "laser", overrides: nil)
      refute laser.visible?("bom")
      refute laser.visible?("wiring")
      refute laser.visible?("releases")
      assert laser.visible?("build_log")

      electronics = Maker::ProjectKind.layout_for(kind: "electronics", overrides: nil)
      assert_equal %w[attachments photos schematics wiring build_log], electronics.visible.first(5)
    end

    test "an unknown kind falls back to other's preset rather than raising" do
      assert_equal Maker::Project::PANELS, Maker::ProjectKind.layout_for(kind: "wormhole", overrides: nil).order
    end

    # --- the overrides ------------------------------------------------------------------------

    test "an override's order wins, and a panel it does not name keeps its preset place" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: { "order" => %w[tasks build_log] })

      assert_equal %w[tasks build_log], layout.order.first(2)
      assert_equal Maker::Project::PANELS.sort, layout.order.sort,
                   "a key the override did not name must be appended, never dropped"
    end

    test "an override's hidden set REPLACES the preset's, including an empty one" do
      shown = Maker::ProjectKind.layout_for(kind: "laser", overrides: { "hidden" => [] })
      assert_equal [], shown.hidden, "unhiding everything a preset hid must survive the merge"

      partial = Maker::ProjectKind.layout_for(kind: "laser", overrides: { "hidden" => %w[tasks] })
      assert_equal %w[tasks], partial.hidden
      assert partial.visible?("bom"), "the preset's hidden set is replaced, not merged into"
    end

    test "an override that names no hidden key at all keeps the preset's" do
      layout = Maker::ProjectKind.layout_for(kind: "laser", overrides: { "order" => %w[tasks] })

      refute layout.visible?("bom")
    end

    # THE READ IS TOTAL. The column is JSON nothing validates on the way in (the v1 API, a console,
    # a later migration), and an unknown key reaches `render "projects/#{key}"` as a MissingPartial
    # — a 500 on the maker's own page. Filtering here is the guard that cannot be bypassed.
    test "garbage in the column is filtered, never raised on" do
      [ nil, {}, "nonsense", [], { "order" => "notalist" },
        { "order" => %w[attachments ../../etc/passwd tasks], "hidden" => %w[bom nope] } ].each do |junk|
        layout = Maker::ProjectKind.layout_for(kind: "other", overrides: junk)
        assert_equal Maker::Project::PANELS.sort, layout.order.sort, junk.inspect
        assert_operator Maker::Project::PANELS.to_set, :superset?, layout.hidden.to_set, junk.inspect
      end
    end

    test "the three always-shown panels cannot be hidden by an override" do
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "hidden" => Maker::Project::PANELS })

      Maker::ProjectKind::ALWAYS.each { |key| assert layout.visible?(key), key }
    end

    # --- the hero -----------------------------------------------------------------------------

    test "hero_roles is a preference list per kind, and other's is today's derivation" do
      assert_equal %w[image model], Maker::ProjectKind.hero_roles("other")
      assert_equal %w[model image], Maker::ProjectKind.hero_roles("print")
      assert_equal %w[pcb image model], Maker::ProjectKind.hero_roles("electronics")
      assert_equal %w[image model], Maker::ProjectKind.hero_roles("wormhole")
    end
  end
end
```

- [ ] **Step 5: run it, expect NameError.** `bin/rails test test/services/maker/project_kind_test.rb`
      → FAIL, `uninitialized constant Maker::ProjectKind`.

- [ ] **Step 6: the model's vocabulary.** In `app/models/maker/project.rb`, directly after the
      `VISIBILITIES`/`LICENSES` block and before the associations (re-anchor on
      `has_many :build_log_entries`):

```ruby
    # THE PROJECT'S TYPE (stage 4, S4-7; decision D4). Suggested from what the folder holds when
    # the app creates the project (Maker::ProjectDiscovery, S4-6's adoption door), editable on the
    # edit form, and never re-derived afterwards — re-suggesting would silently rearrange a page
    # the maker may have arranged themselves, and nothing could tell the two apart.
    KINDS = %w[laser print cnc electronics mixed other].freeze

    # THE PROJECT PAGE'S PANEL LIST, AS DATA (stage 4, S4-7; story 6.5). This order IS `other`'s
    # preset, and `other` is the column default, so a migration alone changes no page (spec §4).
    #
    # ADD A PANEL HERE OR IT RENDERS FOR NOBODY. projects/show.html.erb loops over
    # `Maker::Project#visible_panels` and renders `projects/_<key>`; a tenth partial dropped into
    # the view directory with no entry here is a file no page reaches, and a `render` appended
    # under the loop is a panel the chooser cannot list — one question with two answers (§14a).
    # The key IS the partial's basename; keep them equal.
    #
    # NOTHING OUTSIDE THIS CONSTANT MAY REACH THE LOOP. Maker::ProjectKind.layout_for intersects
    # every stored override with it and Projects::PanelsController intersects every write, so a
    # crafted request cannot put an unknown key in the `panels` column and `render` can never be
    # handed a partial name that does not exist.
    PANELS = %w[attachments photos schematics build_log tasks bom wiring releases sheets publish].freeze

    # What the chooser calls each one. Its own map rather than `key.humanize`, because three of the
    # ten disagree with what humanize would say: `attachments` is "Files" (the panel has been
    # headed Files since S2-2 — the key is the partial's name, and renaming the partial would touch
    # eight call sites), `bom` is "Bill of materials", and `build_log` is "Build log", not
    # "Build Log". A chooser whose labels differ from the headings above them is a chooser nobody
    # trusts. Totality pinned in project_kind_test.rb.
    PANEL_LABELS = {
      "attachments" => "Files", "photos" => "Photos", "schematics" => "Schematics",
      "build_log" => "Build log", "tasks" => "Tasks", "bom" => "Bill of materials",
      "wiring" => "Wiring", "releases" => "Releases", "sheets" => "Sheets", "publish" => "Publish"
    }.freeze
```

Beside `validates :visibility, inclusion: …`:

```ruby
    validates :kind, inclusion: { in: KINDS }
```

**No validation on `panels`, and that is deliberate**: the READ is what has to be safe, and
`Maker::ProjectKind.layout_for` is total (its own comment says why). Add nothing here.

- [ ] **Step 7: the model's readers.** Beside `#current_bom`:

```ruby
    # THE PAGE'S LAYOUT: this kind's preset with this project's own overrides on top (stage 4,
    # S4-7). ProjectsController#show, projects/_panel_chooser and Maker::PublicProject all read
    # THIS, so the maker's page and a visitor's cannot disagree about what is hidden.
    #
    # NOT MEMOIZED. It is array arithmetic over ten strings, and a memo on a mutable attribute is a
    # stale read waiting for the first caller that writes `panels` and reads the layout back in the
    # same request — which is exactly what Projects::PanelsController does.
    def panel_layout = Maker::ProjectKind.layout_for(kind:, overrides: self[:panels])

    def visible_panels = panel_layout.visible
```

- [ ] **Step 8: the hero's preference.** Replace `#derived_cover_node_id`'s body (keep the existing
      comment above it and append the new paragraph):

```ruby
    # The kind's preferred roles first, then the first attachment by position, else nil. Reads the
    # loaded/queried file_attachments; callers that render many cards should
    # include(:file_attachments).
    #
    # THE KIND ONLY REORDERS THE PREFERENCE; IT ADDS NO QUERY AND NO NEW SOURCE (stage 4, S4-7;
    # story 6.3). `hero_roles("other")` is `%w[image model]`, which is exactly what this method did
    # before — first image, else first model, else the first attachment — so every existing project
    # picks the cover it always picked. A 3D-print project prefers a model and an electronics
    # project a board.
    #
    # IT STILL READS THE RELATION, NEVER THE FOLDER, and must keep doing so: #cover_node_id is
    # called once per card on the index, and the comment above forbids a query here for that
    # reason. A discovered project's folder files ARE attachments (Maker::ProjectIntake attaches
    # everything it finds), so the preference has real material to choose from.
    #
    # A STORED `cover_node_id` STILL WINS, because #cover_node_id checks the column first: a preset
    # is a guess about a project, a chosen cover is an answer to the same question, and a guess must
    # never overrule an answer. The stored one is also stable while this one moves as attachments
    # change — which is the asymmetry the column exists to give.
    def derived_cover_node_id
      atts = file_attachments.sort_by { |a| [ a.position, a.id ] }
      pick = Maker::ProjectKind.hero_roles(kind).filter_map { |role| atts.find { |a| a.role == role } }.first
      (pick || atts.first)&.node_id
    end
```

- [ ] **Step 9: create `app/services/maker/project_kind.rb`.**

```ruby
module Maker
  # WHAT KIND OF PROJECT THIS IS, AND WHAT THAT PRESETS (stage 4, S4-7; decision D4; stories
  # 6.1-6.5). Three answers live here and nowhere else: what a folder looks like (#suggest), which
  # panels a kind's page renders and in what order (PRESETS, #layout_for), and which file the hero
  # should prefer (#hero_roles).
  #
  # A KIND IS A GUESS AND THE MAKER'S OVERRIDES ARE AN ANSWER, so #layout_for merges preset then
  # overrides and never the other way round. It is also TOTAL: `panels` is a JSON column nothing
  # validates on the way in, and an unknown key would reach `render "projects/#{key}"` in
  # projects/show.html.erb as a MissingPartial — a 500 on the maker's own page. Filtering here is
  # the guard that cannot be bypassed by the v1 API, a console or a later migration; a write-time
  # validation could be.
  #
  # NOTHING HERE TOUCHES THE PORT. #suggest reads roles off filenames (ProjectFolderListing::Row
  # #role -> Maker::FileAttachment.role_for) and one boolean (#root_repo?), both in memory over a
  # listing built from `nodes`, the catalog all three backends populate — which is why the whole
  # class is testable with no library on disk and behaves identically on the three legs.
  module ProjectKind
    DEFAULT = "other".freeze

    # Plain language, on the edit form and the cards. Not `kind.humanize`: "Electronics & firmware"
    # and "3D printing" are what a maker calls these, and "Cnc" is not a word.
    LABELS = {
      "laser" => "Laser cutting", "print" => "3D printing", "cnc" => "CNC",
      "electronics" => "Electronics & firmware", "mixed" => "Mixed", "other" => "Other"
    }.freeze

    # The panels that open EVERY project page whatever its kind: the folder, then its pictures.
    # A preset may lift panels to sit AFTER these, never before them.
    LEAD = %w[attachments photos].freeze

    # The panels no preset and no override may hide — A DIFFERENT QUESTION FROM `LEAD`, which the
    # two members they share make easy to miss (the same coincidence §14a records for `scannable`
    # and `port_writable` agreeing on three backends). `attachments` is the folder, and the folder
    # is the truth (spec §7). `photos` already omits itself when empty, so hiding it can only ever
    # be invisible or wrong. `publish` is the target of the page head's `#publish` anchor (S4-4),
    # and a dead anchor is worse than a panel nobody wanted.
    ALWAYS = %w[attachments photos publish].freeze

    # ORDER IS DERIVED, NOT SPELLED OUT: `(LEAD + first + PANELS) & PANELS`. Only `electronics`
    # supplies a `first`, so five of the six kinds cannot drift from PANELS at all, and the sixth
    # says only what story 6.2 asks for — schematic and wiring at the top.
    #
    # `schematics` IS IN NO HIDDEN SET, AND THAT IS AN ARGUMENT. projects/_schematics renders
    # nothing when the folder holds no KiCad file, so hiding it for laser/print/cnc has no
    # observable effect EXCEPT in the one case where it is wrong — a laser project that does hold a
    # board. A default that can only be invisible or wrong is not worth having.
    #
    # WHY EACH HIDDEN SET IS WHAT IT IS: `laser` is story 6.1 verbatim ("not BOM, wiring and
    # releases") plus `sheets`, which story 6.1 does not name among what should come first and
    # which real use puts at zero across nine projects. `print` keeps `bom` because a printed
    # assembly is printed parts plus hardware. `cnc` drops `bom` because a milled part is one
    # billet, and keeps `sheets` because feeds, speeds and a job sheet are the CNC bench's
    # paperwork. `electronics` hides only `sheets`. `mixed` and `other` hide nothing, and `other`
    # is the column default — which is what makes this migration invisible to every existing
    # project (spec §4).
    PRESETS = {
      "laser"       => { first: [],                    hidden: %w[bom wiring releases sheets] },
      "print"       => { first: [],                    hidden: %w[wiring releases sheets] },
      "cnc"         => { first: [],                    hidden: %w[bom wiring releases] },
      "electronics" => { first: %w[schematics wiring], hidden: %w[sheets] },
      "mixed"       => { first: [],                    hidden: [] },
      "other"       => { first: [],                    hidden: [] }
    }.freeze

    # WHICH FILE THE HERO PREFERS, as a preference LIST rather than one role, so a print project
    # with no model attached still shows its photo instead of nothing. `other`'s list is
    # `%w[image model]`, which is Maker::Project#derived_cover_node_id's original
    # `find image || find model || first` written as data — that equality is what makes this
    # migration invisible, and project_kind_test.rb asserts it directly.
    HERO_ROLES = {
      "print" => %w[model image], "electronics" => %w[pcb image model]
    }.freeze
    DEFAULT_HERO_ROLES = %w[image model].freeze

    # --- the suggestion -------------------------------------------------------------------------

    # The families a folder is read for. Each is a pair of roles that arrive together on one bench:
    # `.lbrn2` beside the `.svg` it was drawn from, a `.stl` beside the `.step` it was exported
    # from, a `.nc` beside the `.mage` that generated it, a `.c` beside the Gerbers it drives.
    # ROLES THIS MAP DOES NOT NAME ARE DELIBERATELY SILENT: `image`, `document`, `instructions`,
    # `source_archive` and `other` appear in every kind of project, so counting them would say
    # nothing about which kind this is.
    FAMILIES = {
      "laser"       => %w[laser vector],
      "print"       => %w[model cad_source],
      "cnc"         => %w[gcode cnc_design],
      "electronics" => %w[code pcb]
    }.freeze

    # A `.git` marker at the folder's own root is EVIDENCE, not a verdict. All three real
    # repositories on the share deployment are firmware, so it counts toward electronics — and it
    # counts for TWO files' worth, which is enough to name a checkout holding only a README and not
    # nearly enough to outvote five laser files. Both halves are pinned in project_kind_test.rb.
    REPO_WEIGHT = 2

    # A SECOND STRONG FAMILY MAKES IT `mixed`, and "strong" is measured against the LEADER rather
    # than against the folder's total: a project with forty photos and two SVGs is a laser project,
    # while one with six SVGs and six STLs is genuinely both. Half the leader is the line.
    MIXED_SHARE = 0.5

    # The kind this folder looks like. Reads at most ProjectFolderListing::FILE_CAP rows (300),
    # in memory, no query of its own.
    def self.suggest(listing)
      rows = listing.all_rows
      counts = FAMILIES.transform_values { |roles| rows.count { |row| roles.include?(row.role) } }
      counts["electronics"] += REPO_WEIGHT if listing.root_repo?

      # Deterministic: by count, then by FAMILIES' own order, so the same folder always answers the
      # same kind. A tie goes to `mixed` below in any case — this only keeps the sort stable.
      ranked = counts.reject { |_kind, n| n.zero? }
                     .sort_by { |kind, n| [ -n, FAMILIES.keys.index(kind) ] }
      return DEFAULT if ranked.empty?

      top_kind, top = ranked.first
      runner = ranked.dig(1, 1).to_i
      runner >= (top * MIXED_SHARE) ? "mixed" : top_kind
    end

    # THE DOOR EVERY WRITER USES. It answers about a FOLDER, so it can be asked before the project
    # row exists — which is what lets `kind:` be part of Maker::ProjectDiscovery's `create!` rather
    # than an `update_column` after it: one write, and a project is never momentarily `other`.
    #
    # THE THROWAWAY `Maker::Project.new` IS NOT A SMELL, IT IS THE CONTRACT: ProjectFolderListing
    # reads exactly one attribute of the project it is handed, `project.folder_node_id.presence`
    # (project_folder_listing.rb), and widening its constructor to take a bare id would be a change
    # to a class four other slices are editing.
    #
    # `tree:` IS HOW A SWEEP PAYS THE DIRS PLUCK ONCE. Without it, Maker::ProjectDiscovery's capped
    # run would build fifty LibraryTrees; with it, one, plus two queries per project created.
    def self.suggest_for(user:, folder_node_id:, tree: nil)
      return DEFAULT if folder_node_id.blank?

      listing = Maker::ProjectFolderListing.new(user, Maker::Project.new(folder_node_id:),
                                                tree: tree || Maker::LibraryTree.new(user))
      suggest(listing)
    end

    # --- the layout -----------------------------------------------------------------------------

    # One project page's panel list. `order` is always a permutation of Maker::Project::PANELS;
    # `hidden` is always a subset of it with ALWAYS removed. `visible` is what the loop renders.
    Layout = Data.define(:order, :hidden) do
      def visible = order - hidden
      def visible?(key) = order.include?(key) && !hidden.include?(key)
      def hidden?(key) = hidden.include?(key)
    end

    def self.label(kind) = LABELS.fetch(kind.to_s, LABELS.fetch(DEFAULT))

    def self.hero_roles(kind) = HERO_ROLES.fetch(kind.to_s, DEFAULT_HERO_ROLES)

    # THE MAKER'S ANSWER WINS, INCLUDING "nothing hidden" — which is why the test below is `key?`
    # and not `.present?`. A maker who unhides every panel their kind's preset hid stores
    # `"hidden" => []`, and `.present?` would read that as "no override" and hand the preset
    # straight back: the Save button would visibly do nothing for exactly the maker who used it.
    #
    # A PANEL THE STORED ORDER DOES NOT NAME IS APPENDED IN ITS PRESET PLACE, NEVER DROPPED.
    # Shipping an eleventh panel would otherwise make it invisible to every project that has ever
    # saved a layout — silently, and only for the makers who used the feature.
    #
    # AN UNKNOWN KIND FALLS BACK TO `other`'s PRESET rather than raising: `kind` is validated on the
    # way in, but a row written before a kind was retired, or by a future version, must still
    # render a page.
    def self.layout_for(kind:, overrides:)
      preset = PRESETS.fetch(kind.to_s, PRESETS.fetch(DEFAULT))
      over = overrides.is_a?(Hash) ? overrides : {}

      order = (known(over["order"]) + preset_order(preset))
      hidden = (over.key?("hidden") ? known(over["hidden"]) : preset[:hidden]) - ALWAYS
      Layout.new(order: order & Maker::Project::PANELS, hidden:)
    end

    # `Array#&` FILTERS, DEDUPS AND KEEPS THE RECEIVER'S ORDER in one operation, which is all three
    # things this needs — and it is what makes the read total: a key that is not a panel simply is
    # not there, whatever wrote it.
    def self.known(list) = Array(list).map(&:to_s) & Maker::Project::PANELS

    def self.preset_order(preset) = (LEAD + preset[:first] + Maker::Project::PANELS) & Maker::Project::PANELS
    private_class_method :known, :preset_order
  end
end
```

- [ ] **Step 10: run, expect PASS.** `bin/rails test test/services/maker/project_kind_test.rb` →
      0 failures. Then `bin/rails test test/models/maker/project_test.rb test/integration/web/project_cover_test.rb`
      → the existing cover derivation must be untouched.

- [ ] **Step 11: the model test.** Append to `test/models/maker/project_test.rb` (copy its own
      `setup`'s user idiom):

```ruby
  # STAGE 4, S4-7: the column defaults are what make the migration invisible (spec §4).
  test "a new project is other, with no overrides and today's panel list" do
    project = @user.maker_projects.create!(name: "Fresh")

    assert_equal "other", project.kind
    assert_nil project[:panels]
    assert_equal Maker::Project::PANELS, project.visible_panels
  end

  test "kind is validated against KINDS" do
    project = @user.maker_projects.new(name: "Bad", kind: "wormhole")

    refute project.valid?
    assert_includes project.errors[:kind].join, "not included"
  end

  # THE PRESET IS A GUESS; A CHOSEN COVER IS AN ANSWER. Asserted through #cover_node_id (the
  # reader every card and the hero use), not through #derived_cover_node_id, because the ordering
  # of those two is the rule.
  test "a print project prefers a model for its hero, and a chosen cover still wins" do
    project = @user.maker_projects.create!(name: "Bracket", kind: "print")
    project.file_attachments.create!(user: @user, node_id: "img", role: "image", position: 0)
    project.file_attachments.create!(user: @user, node_id: "mdl", role: "model", position: 1)

    assert_equal "mdl", project.cover_node_id

    project.update!(cover_node_id: "img")
    assert_equal "img", project.cover_node_id
  end

  test "an other project's hero is the image, exactly as before the kind existed" do
    project = @user.maker_projects.create!(name: "Tray")
    project.file_attachments.create!(user: @user, node_id: "mdl", role: "model", position: 0)
    project.file_attachments.create!(user: @user, node_id: "img", role: "image", position: 1)

    assert_equal "img", project.cover_node_id
  end
```

- [ ] **Step 12: mutation checks.** Four, each run and its output reported.
  (i) In `layout_for`, change `over.key?("hidden")` to `over["hidden"].present?` → the
      "an override's hidden set REPLACES the preset's, including an empty one" test FAILS
      (`Expected: [] Actual: ["bom", "wiring", "releases", "sheets"]`).
  (ii) In `layout_for`, drop `& Maker::Project::PANELS` from the `Layout.new` line → the
      "garbage in the column is filtered" test FAILS on the `../../etc/passwd` row.
  (iii) In `layout_for`, drop `- ALWAYS` → the "three always-shown panels" test FAILS.
  (iv) In `derived_cover_node_id`, replace `Maker::ProjectKind.hero_roles(kind)` with
      `Maker::ProjectKind::DEFAULT_HERO_ROLES` → the print-hero model test FAILS
      (`Expected: "mdl" Actual: "img"`).
  Restore each with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after (ii) and (iii),
  which are equal-length edits; re-run and report the green output.

- [ ] **Step 13: verify the three derived guards need no edit.**
      `bin/rails test test/schema_map_test.rb test/models/tenant_cleanup_test.rb test/models/structural_orphan_test.rb`
      → PASS. `schema_map_test.rb` passes only because step 3 regenerated `docs/schema-map.html`;
      the other two derive their case lists from the schema and neither column is a `user_id` nor a
      structural edge, so **expect no edit and make none**.

- [ ] **Step 14: commit.**

```bash
git add db/migrate/20260907160000_add_kind_and_panels_to_maker_projects.rb db/schema.rb docs/schema-map.html \
        app/models/maker/project.rb app/services/maker/project_kind.rb \
        test/services/maker/project_kind_test.rb test/models/maker/project_test.rb
git commit -m "A project has a kind, and a kind presets which panels its page shows and which file its hero prefers"
```
Name in the message whether `publish` is in `PANELS` (amendment 9).

---

### Task B: who writes the suggested kind

Starts after A has committed. Runs in parallel with C.

**Files:**
- Modify: `app/services/maker/project_discovery.rb`; **conditionally** `app/controllers/projects/adoptions_controller.rb`
- Test: `test/services/maker/project_discovery_test.rb`; **conditionally** `test/integration/web/project_adoptions_test.rb`

**Re-anchor, do not trust line numbers.** If S4-6 has merged, `.for_user`'s loop already reads
`created = []` … `discovered_at: now` … `created << name`; if it has not, it reads `created = 0`
… `created += 1`. Anchor on the literal `candidates.first(cap).each do |node_id, name|` and on the
`create!(` call inside it, and keep every comment already in that call (the `available_slug` note,
the "THE FOLDER ALREADY EXISTS" note, and S4-6's `discovered_at` note if present).

- [ ] **Step 1: the failing discovery tests.** Append to `test/services/maker/project_discovery_test.rb`
      (its `setup` already makes `@user` and `@root`, and it has `dir`/`file` helpers):

```ruby
    # STAGE 4, S4-7 (decision D4): the sweep names what it adopted. A discovered folder is the ONE
    # case where the app has files in front of it at creation time, so it is where a kind can be
    # suggested at all — the web form mints an empty folder and has nothing to read.
    test "a discovered folder is created with the kind its files suggest" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      %w[box.lbrn2 lid.lbrn panel.svg tray.dxf].each_with_index { |n, i| file("f-#{i}", n, lamp.node_id) }

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal "laser", @user.maker_projects.sole.kind
    end

    # THE DEFAULT IS STILL THE DEFAULT. A folder with nothing recognisable in it must not be
    # guessed at, and `other`'s preset is today's page (spec §4).
    test "a folder with nothing to read is created as other" do
      dir("d-empty", "Empty", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal "other", @user.maker_projects.sole.kind
    end

    # ONE WRITE, NEVER A CREATE-THEN-UPDATE: a project is never momentarily `other`, so nothing
    # that watches maker_projects (the eager intake chain, a device push) can observe a kind that
    # was never true. Asserted on the row's own updated_at against its created_at rather than by
    # counting statements, which no public API here exposes.
    test "the kind is part of the create, not an update after it" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      %w[base.stl body.step].each_with_index { |n, i| file("f-#{i}", n, lamp.node_id) }

      Maker::ProjectDiscovery.for_user(user: @user)

      project = @user.maker_projects.sole
      assert_equal "print", project.kind
      assert_equal project.created_at, project.updated_at
    end

    # THE SWEEP STILL TOUCHES NO PORT (the class's own header claim). The suggestion reads `nodes`,
    # which every backend populates — so this test passes identically on the three legs and needs
    # no library on disk. Driven, not reasoned: FileLayer.current is never constructed here.
    test "the suggestion reads the catalog and nothing else" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      file("f-0", "main.c", lamp.node_id)
      file("f-1", "board.gtl", lamp.node_id)

      assert_equal "electronics", Maker::ProjectKind.suggest_for(user: @user, folder_node_id: lamp.node_id)
    end
```

- [ ] **Step 2: run, expect FAIL.** `bin/rails test test/services/maker/project_discovery_test.rb -n /kind/`
      → FAIL, `Expected: "laser" Actual: "other"`.

- [ ] **Step 3: wire the suggestion into the sweep.** In `.for_user`, immediately before
      `candidates.first(cap).each`:

```ruby
      # ONE TREE FOR THE WHOLE RUN (stage 4, S4-7). Maker::ProjectKind.suggest_for would otherwise
      # build a LibraryTree per candidate — one dirs pluck each, fifty of them at the cap. Shared,
      # the run pays that pluck once plus TWO queries per project it actually creates (the
      # listing's files query and its count), which is 100 in a first run and ZERO in the steady
      # state, where `created` is 0. Built here rather than at the top of the method so a
      # :no_projects_folder run still builds nothing.
      tree = Maker::LibraryTree.new(user)
```

and inside the `create!`, after `folder_node_id: node_id` (and after S4-6's `discovered_at:` if it
is there):

```ruby
          # WHAT THE FOLDER LOOKS LIKE (stage 4, S4-7; decision D4). Suggested ONCE, here, from the
          # files that are already in the folder — this sweep is the only door that has files in
          # front of it at creation time, since the web form mints an empty folder and has nothing
          # to read. Never re-derived afterwards: re-suggesting would silently rearrange a page the
          # maker may have arranged themselves, and nothing could tell the two apart.
          #
          # PART OF THE CREATE, not an update after it, which is what `suggest_for` taking a FOLDER
          # rather than a project is for — the project is never momentarily `other`.
          kind: Maker::ProjectKind.suggest_for(user:, folder_node_id: node_id, tree:)
```

- [ ] **Step 4: keep the class's header true.** In `project_discovery.rb`'s header, the paragraph
      beginning "IT NEVER TOUCHES THE PORT" currently says it "writes maker_projects rows and
      nothing else". Replace that clause:

```ruby
  # IT NEVER TOUCHES THE PORT. It writes maker_projects rows and READS `nodes` — the catalog all
  # three backends populate — to suggest each new project's kind (stage 4, S4-7); no mkdir, no
  # move, no bytes. That is what makes it identical on all three backends and testable without a
  # library on disk.
```
This is §15's "when a change invalidates a documented behaviour, the same task sweeps every file
that documents it" — the sentence was true when it was written and is not any more.

- [ ] **Step 5: run, expect PASS.** `bin/rails test test/services/maker/project_discovery_test.rb`
      → 0 failures, and the pre-existing tests (delta reporting, the cap, the unscoped claim
      lookup) unchanged.

- [ ] **Step 6: the adoption door, CONDITIONALLY (amendment 8).**
      `ls app/controllers/projects/adoptions_controller.rb`.

  **If it exists** (S4-6 merged first) — in `#adopt!`'s `create!`, after `autofile: false`:

```ruby
          # THE FOLDER SAYS WHAT IT IS (stage 4, S4-7). Adoption reads the same suggestion
          # discovery does, from the same door, because "make this folder a project" hands the app
          # a folder that is already full — which is exactly the case a suggestion is for. No tree
          # is passed: this is one folder in one request, not a capped sweep.
          kind: Maker::ProjectKind.suggest_for(user: current_user, folder_node_id: node.node_id)
```

  and append to `test/integration/web/project_adoptions_test.rb`:

```ruby
    # STAGE 4, S4-7: adopting a full folder reads it, exactly as discovery does.
    test "an adopted folder is created with the kind its files suggest" do
      tray = @user.nodes.create!(node_id: "d-tray", name: "tray", kind: "dir",
                                 parent_node_id: nil, mtime: 1, size: 0)
      %w[base.stl body.step clip.stl].each_with_index do |n, i|
        @user.nodes.create!(node_id: "a-#{i}", name: n, kind: "file",
                            parent_node_id: tray.node_id, mtime: 1, size: 1)
      end

      post project_adoptions_path, params: { node_id: tray.node_id }

      assert_equal "print", @user.maker_projects.find_by!(folder_node_id: tray.node_id).kind
    end
```
  (Re-anchor the request line and the fixture on whatever `project_adoptions_test.rb` actually
  does — S4-6's plan names `Projects::AdoptionsController#create`; read the committed route and
  copy its own idiom rather than the shape guessed here.)

  **If it does not exist**, do nothing and say so — Task F step 3 records the obligation in the
  overview's S4-6 territory section. **Do not create that controller here.**

- [ ] **Step 7: mutation check.** In `.for_user`, replace `tree:` in the `suggest_for` call with
      `tree: nil` and run `test/integration/web/page_query_budget_test.rb` — it stays green, because
      no page in it runs discovery, **which is the point**: this saving has no guard and is a
      measured cost bound rather than an asserted one. Restore. Then the real mutation: replace the
      whole `kind:` line with `kind: "other"` and run
      `bin/rails test test/services/maker/project_discovery_test.rb -n /kind/` → the laser, print
      and electronics cases FAIL. Restore; PASS. Report both outputs.

- [ ] **Step 8: commit.**

```bash
git add app/services/maker/project_discovery.rb test/services/maker/project_discovery_test.rb
# plus the two adoption files if step 6 applied
git commit -m "A folder the app adopts is read for what it is, once, as it is created"
```

---

### Task C: the loop, the chooser and its door

Starts after A has committed. Runs in parallel with B.

**Files:**
- Modify: `app/controllers/projects_controller.rb` (`#show`, `#index`, `#project_params`),
  `app/views/projects/show.html.erb`, `config/routes.rb`,
  `app/assets/stylesheets/pages/projects.css`
- Create: `app/views/projects/_panel_chooser.html.erb`, `app/controllers/projects/panels_controller.rb`
- Test: `test/integration/web/project_page_test.rb`, new `test/integration/web/project_panels_test.rb`

- [ ] **Step 1: the failing page tests.** Append to `test/integration/web/project_page_test.rb`
      (its `setup` signs `@user` in and gives `@project` two folder files, three tasks, an entry
      and a sheet):

```ruby
    # STAGE 4, S4-7 (story 6.5): the panel list is data, and `other` — the column default — is
    # exactly the page this project had before the column existed.
    # THE LOOP RENDERS WHAT THE HARD-CODED LIST RENDERED, IN THE SAME ORDER. Asserted as a
    # SUBSEQUENCE of the canonical list rather than as an equal array: which panels this fixture
    # reaches depends on what it seeds (no image, so no Photos; no KiCad, so no Schematics), and a
    # test that had to enumerate that would go red whenever an unrelated fixture line changed.
    # What must hold is that nothing is out of order and nothing unknown appears.
    test "an other project renders its panels in the canonical order" do
      get project_path(@project)

      assert_response :success
      expected = Maker::Project::PANELS.map { |k| "#{k.tr("_", "-")}-panel" }
      rendered = css_select("div.project-panels > section.panel")
                 .map { |s| s["class"].split.find { |c| c.end_with?("-panel") } }

      assert_equal rendered, expected & rendered,
                   "the loop rendered #{rendered.inspect}, which is not in PANELS order"
      assert_includes rendered, "attachments-panel"
      assert_includes rendered, "build-log-panel"
      assert_includes rendered, "tasks-panel"
      assert_includes rendered, "sheets-panel"
    end

    test "a hidden panel is not rendered at all — not quiet, absent" do
      @project.update!(panels: { "hidden" => %w[tasks bom wiring] })

      get project_path(@project)

      assert_select "section.tasks-panel", count: 0
      assert_select "section.bom-panel", count: 0
      assert_select "section.wiring-panel", count: 0
      assert_select "section.build-log-panel", 1, "an unhidden panel is untouched"
      assert_select "section.attachments-panel", 1
    end

    # HIDDEN AND EMPTY ARE TWO QUESTIONS (the overview's quiet-panel contract). An empty panel that
    # is NOT hidden still renders, quiet — S4-1's state — and a hidden one is gone whether it is
    # empty or full. Both halves in one test, because it is the pair that must not collapse.
    test "hidden and quiet are different states" do
      empty = @user.maker_projects.create!(name: "Blank")

      get project_path(empty)
      assert_select "section.wiring-panel.panel--quiet", 1

      empty.update!(panels: { "hidden" => %w[wiring] })
      get project_path(empty)
      assert_select "section.wiring-panel", count: 0
    end

    test "a stored order reorders the DOM, and a preset does too" do
      @project.update!(panels: { "order" => %w[tasks build_log] })

      get project_path(@project)
      panels = css_select("div.project-panels > section.panel").map { |s| s["class"] }
      assert_operator panels.index { |c| c.include?("tasks-panel") }, :<,
                      panels.index { |c| c.include?("build-log-panel") },
                      "the stored order must move Tasks above Build log"

      @project.update!(panels: nil, kind: "electronics")
      @project.connections.create!(user: @user, from_label: "A", to_label: "B")
      get project_path(@project)
      panels = css_select("div.project-panels > section.panel").map { |s| s["class"] }
      assert_operator panels.index { |c| c.include?("wiring-panel") }, :<,
                      panels.index { |c| c.include?("build-log-panel") },
                      "electronics lifts Wiring above the build log (story 6.2)"
    end

    # THE THREE PANELS NOBODY MAY HIDE (Maker::ProjectKind::ALWAYS). Driven through a real request
    # rather than asserted on the constant, because the thing that must hold is what the PAGE does
    # with a column someone wrote by hand.
    test "Files stays on the page however hard the column tries to hide it" do
      @project.update!(panels: { "hidden" => Maker::Project::PANELS })

      get project_path(@project)

      assert_select "section.attachments-panel", 1
    end

    # A KEY THAT IS NOT A PANEL MUST NOT REACH `render` — it would be a MissingPartial, i.e. a 500
    # on the maker's own page, and the column is JSON nothing validates on the way in.
    test "junk in the panels column renders the page rather than raising" do
      @project.update_column(:panels, { "order" => [ "attachments", "../../etc/passwd" ], "hidden" => "nope" })

      get project_path(@project)

      assert_response :success
      assert_select "section.attachments-panel", 1
    end
```

- [ ] **Step 2: run, expect FAIL.** `bin/rails test test/integration/web/project_page_test.rb`
      → the hidden/order tests fail (every panel still renders, in the hard-coded order).

- [ ] **Step 3: the controller.** In `ProjectsController#show`, five edits.

(a) At the very top of the method, above the `# A FILE DELETED FROM THE LIBRARY…` comment:

```ruby
    # THE PAGE'S PANEL LIST, FIRST (stage 4, S4-7; story 6.5): this project's kind's preset with its
    # own overrides on top. Zero queries — it reads two columns off the row `set_project` already
    # loaded — and it is read before the loads below because three of them are SKIPPED when their
    # panel is hidden.
    @panel_layout = @project.panel_layout
```

(b) The BOM block. Replace the six lines from `@bom = @project.current_bom` through `@suppliers = …`:

```ruby
    # SKIPPED WHEN THE PANEL IS HIDDEN (stage 4, S4-7) — four queries: the bom, its lines, the item
    # names and the supplier names, the last two of which exist only for the panel's composer.
    #
    # WHY THIS ONE IS SAFE TO SKIP AND `@tasks`/`@sheets`/`@entries` ARE NOT: `@bom_lines` does feed
    # the page's ONE PageNodes union below, but ONLY so projects/_bom_lines can resolve a file
    # line's node — nothing else on the page reads a BOM node id out of that union, so an empty
    # list narrows it and changes no other panel. `@tasks` and `@sheets` are counted by the STATS
    # LINE and `@entries` is read by Maker::ProjectPhotos through entry_photo_ids, so skipping any
    # of those three would change a surface other than its own panel.
    bom_shown = @panel_layout.visible?("bom")
    @bom = bom_shown ? @project.current_bom : nil
    @bom_lines = @bom ? @bom.lines.includes(:inventory_item, :supplier).to_a : []
    @bom_lines_shown = @bom_lines.first(Projects::BomLinesController::PANEL_CAP)
    @bom_rollup = Maker::BomRollup.new(@bom_lines)
    @items = bom_shown ? current_user.maker_inventory_items.order(:name).pluck(:name, :id) : []
    @suppliers = bom_shown ? current_user.maker_suppliers.order(:name).pluck(:name, :id) : []
```

(c) The releases block. Replace `@releases = @project.releases.includes(…)` with:

```ruby
    # SKIPPED WHEN HIDDEN (stage 4, S4-7), and this is the most expensive of the three: the
    # releases query, the ONE `stat_all` over every file of every release — a PORT round trip, and
    # a WAN one on chunk_remote — and, where the library is a local folder, a git tag read per
    # repository in the folder. `release_node_ids` is empty when @releases is, so `stat_all` already
    # short-circuits; only @release_repos needs the gate spelled out.
    releases_shown = @panel_layout.visible?("releases")
    @releases = releases_shown ? @project.releases.includes(:files, :rich_text_notes).to_a : []
```
and change the `@release_repos` line to:
```ruby
    @release_repos = releases_shown && capabilities.local_worktree? ? release_repo_tags(repo_dirs, repo_roots) : []
```

(d) The wiring line. Replace `@connections = @project.connections.to_a` with:

```ruby
    # SKIPPED WHEN HIDDEN (stage 4, S4-7) — one query, and projects/_wiring is its only reader.
    @connections = @panel_layout.visible?("wiring") ? @project.connections.to_a : []
```

(e) Beside `@scan_started`:

```ruby
    # THE CHOOSER'S RE-OPEN HINT (stage 4, S4-7). Every write to the panel layout redirects back
    # here with `?panels=open`, so a maker clicking Up four times does not have to reopen the
    # <details> between clicks. A one-shot RENDER HINT, not state — which is why it rides in the
    # url exactly as @scan_started does, and is gone the moment they navigate away.
    @panels_open = params[:panels] == "open"
```

- [ ] **Step 4: the loop.** In `app/views/projects/show.html.erb`, replace the whole
      `<div class="project-panels"> … </div>` block (from the line reading
      `<div class="project-panels">` to its closing `</div>`, i.e. everything after
      `<%= render "hero" %>`) with:

```erb
<%#
  THE PANELS, AS DATA (stage 4, S4-7; story 6.5). Nine hard-coded renders became one loop over
  Maker::Project#visible_panels — this project's kind's preset with its own overrides on top. The
  key IS the partial's basename, and Maker::Project::PANELS is the only place a key may come from:
  Maker::ProjectKind.layout_for intersects the stored column with it and
  Projects::PanelsController intersects every write, so this render can never be handed a partial
  name that does not exist.

  HIDDEN IS NOT QUIET. A panel this loop skips is absent from the page; an empty panel it DOES
  render is quiet (S4-1's panel--quiet) — its heading and one add control. Two questions, and the
  overview's quiet-panel contract is what keeps them two.

  THE LOCALS MAP EXISTS BECAUSE THREE PARTIALS TAKE LOCALS AND SIX READ IVARS, and neither group
  may be converted: projects/_wiring, projects/_releases and projects/_publish take locals so the
  PUBLIC page can render the same markup without aliasing its own ivars to this page's names --
  each of those partials says so in its own header. Every value here is an ivar
  ProjectsController#show has already loaded, so building the map costs nothing, including for a
  panel this loop is about to skip.
%>
<% panel_locals = {
     "wiring"   => { project: @project, connections: @connections, editable: true },
     "releases" => { project: @project, releases: @releases, current_tokens: @release_tokens,
                     repos: @release_repos, editable: true },
     "publish"  => { project: @project }
   } %>
<div class="project-panels">
  <% @panel_layout.visible.each do |key| %>
    <%= render "projects/#{key}", **panel_locals.fetch(key, {}) %>
  <% end %>
</div>

<%= render "panel_chooser" %>
```

**If `publish` is not in `PANELS`** (amendment 9), leave S4-4's `render "publish"` where it is and
drop the `"publish"` entry from `panel_locals`.

- [ ] **Step 5: the chooser.** Create `app/views/projects/_panel_chooser.html.erb`:

```erb
<%#
  WHICH PANELS THIS PROJECT'S PAGE SHOWS, AND IN WHAT ORDER (stage 4, S4-7; story 6.5). On the page
  the choice is about, closed by default, below the panels — so a settings box never displaces the
  maker's own content, which is the argument S4-4's Publish panel already makes for sitting last.
  Each click re-renders this page with the panels where they now are, which is the whole reason it
  is not on the edit form.

  NO JAVASCRIPT AND NO STIMULUS CONTROLLER. Show/hide is one form of checkboxes with a Save; Up and
  Down are one button_to each. Naming a data-controller that does not exist is a SILENT no-op
  (§14d), so this names none.

  A form CANNOT CONTAIN A button_to's OWN FORM, so the checkbox form is declared EMPTY above the
  list and every checkbox, every hidden order field and the Save button point back at it by id
  through the HTML `form` attribute -- the idiom projects/_wiring.html.erb already uses because a
  form cannot span table cells. project_panels_test.rb asserts that wiring directly.

  EVERY KEY IS LISTED, hidden ones included and unchecked: reordering has to reach a panel you
  cannot currently see, and a move rewrites the FULL order so a hidden panel keeps its slot instead
  of collapsing to the end the moment it is shown again. The three in Maker::ProjectKind::ALWAYS
  carry a hidden field instead of a checkbox, so the Save that follows cannot ask for something the
  layout would refuse anyway.

  check_box_tag EMITS NO HIDDEN "0" COMPANION, and here that is correct rather than the gap
  CLAUDE.md section 14d records for a form builder's check_box against a persisted column. An
  unchecked box sends nothing at all, which is precisely why the panels[order][] hidden fields
  carry the COMPLETE list: the door computes hidden as order minus visible, so "unchecked" and
  "not offered" are the same fact, and neither can silently drop a panel out of the order.

  Reads @project, @panel_layout and @panels_open (ProjectsController#show). No locals.
%>
<details class="panel-chooser" id="panels" <%= "open" if @panels_open %>>
  <summary class="btn small">Panels</summary>

  <p class="muted panel-chooser-note">
    This project is <b><%= Maker::ProjectKind.label(@project.kind) %></b>.
    <%= link_to "Change its type", edit_project_path(@project) %>
  </p>

  <%# The EMPTY form every field below points at. `scope:` is not needed and would be wrong: the
      fields are named by hand (panels[order][] and panels[visible][]) so the controller reads one
      array of keys and one array of the checked subset, and a form builder is not involved. %>
  <%= form_with url: project_panels_path(@project), method: :patch, id: "panel-visibility" do %><% end %>

  <ol class="panel-choices">
    <% @panel_layout.order.each do |key| %>
      <li class="panel-choice">
        <%= hidden_field_tag "panels[order][]", key, form: "panel-visibility", id: "panel-order-#{key}" %>
        <% if Maker::ProjectKind::ALWAYS.include?(key) %>
          <%= hidden_field_tag "panels[visible][]", key, form: "panel-visibility", id: "panel-show-#{key}" %>
          <span class="panel-choice-name"><%= Maker::Project::PANEL_LABELS.fetch(key) %></span>
          <span class="muted panel-choice-always">always shown</span>
        <% else %>
          <label class="panel-choice-name">
            <%= check_box_tag "panels[visible][]", key, @panel_layout.visible?(key),
                              form: "panel-visibility", id: "panel-show-#{key}" %>
            <%= Maker::Project::PANEL_LABELS.fetch(key) %>
          </label>
        <% end %>
        <span class="panel-choice-moves">
          <%= button_to "▲", project_panels_path(@project), method: :patch,
                        params: { move: "up", panel: key }, class: "linkbtn small",
                        form: { "aria-label" => "Move #{Maker::Project::PANEL_LABELS.fetch(key)} up" } %>
          <%= button_to "▼", project_panels_path(@project), method: :patch,
                        params: { move: "down", panel: key }, class: "linkbtn small",
                        form: { "aria-label" => "Move #{Maker::Project::PANEL_LABELS.fetch(key)} down" } %>
        </span>
      </li>
    <% end %>
  </ol>

  <div class="panel-chooser-actions">
    <%= submit_tag "Save panels", form: "panel-visibility", class: "btn small primary" %>
    <%# DELETE, because reset means REMOVE THE OVERRIDE — writing today's preset into the column
        instead would freeze this release's defaults onto the row and stop the project tracking its
        own kind for ever. %>
    <%= button_to "Reset to #{Maker::ProjectKind.label(@project.kind)} defaults",
                  project_panels_path(@project), method: :delete, class: "linkbtn small" %>
  </div>
</details>
```

- [ ] **Step 6: the route.** In `config/routes.rb`, inside `resources :projects do`, beside
      `resource :scan, only: :create, module: :projects`:

```ruby
    # WHICH PANELS THIS PROJECT'S PAGE SHOWS (stage 4, S4-7; story 6.5). SINGULAR: there is one
    # layout per project and nothing to identify. PATCH writes it — a reorder (`move`) and a
    # show/hide Save are two shapes on the one verb, because both edit the same one thing — and
    # DELETE resets it by REMOVING the override, never by writing the current preset into the row.
    # `controller_path` is "projects/panels", whose first segment is "projects", so
    # ShellHelper::SECTIONS needs no entry and the rail still lights Projects.
    resource :panels, only: %i[update destroy], module: :projects
```

- [ ] **Step 7: the door.** Create `app/controllers/projects/panels_controller.rb`:

```ruby
module Projects
  # The project page's own panel layout: show/hide, reorder, reset (stage 4, S4-7; story 6.5).
  #
  # IT WRITES ONLY KEYS FROM Maker::Project::PANELS, and that is structural rather than a
  # validation someone can loosen: every array below is intersected with that constant before it
  # reaches the column, so a crafted request cannot put `../../etc/passwd` in `panels["order"]` and
  # projects/show.html.erb's `render "projects/#{key}"` can never be handed a partial name that
  # does not exist. Maker::ProjectKind.layout_for filters again on the way OUT, for the rows this
  # door did not write (the v1 API, a console, a later migration) — two filters, one at each end,
  # because only the read one cannot be bypassed.
  #
  # ONE PATCH, TWO SHAPES. `?move=up` reorders and carries no `panels` key at all, so the branch is
  # taken BEFORE `params.require(:panels)` — a move must not 400 on a key it never sends.
  #
  # EVERY RESPONSE REDIRECTS BACK TO THE PAGE WITH `?panels=open`. The chooser is a <details> and
  # this is a full page reload with no JavaScript anywhere, so without the hint every click would
  # close it and the maker would reopen it to click again. It is a render hint, not state
  # (ProjectsController#show reads it into @panels_open) — the same shape as `?scanning=1`.
  class PanelsController < ApplicationController
    before_action :set_project

    def update
      @project.update!(panels: params[:move].present? ? moved : chosen)
      redirect_to back_to_panels, notice: "Panels updated."
    end

    # RESET MEANS REMOVE THE OVERRIDE, not "write the current preset into the column": the second
    # would freeze this release's defaults onto the row and stop the project following its own kind
    # — including after the maker changes that kind on the edit form.
    def destroy
      @project.update!(panels: nil)
      redirect_to back_to_panels,
                  notice: "Panels reset to the #{Maker::ProjectKind.label(@project.kind)} defaults."
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end

    def back_to_panels = project_path(@project, panels: "open", anchor: "panels")

    # A MOVE REWRITES THE FULL ORDER, HIDDEN PANELS INCLUDED, so a panel that is currently hidden
    # keeps its slot rather than collapsing to the end the moment it is shown again — which is also
    # why the chooser lists every key rather than only the visible ones.
    #
    # AN UNKNOWN PANEL OR AN EDGE MOVE IS A NO-OP, NEVER AN ERROR: the buttons are rendered from
    # the same list this reads, so the only way to reach either is a hand-made request, and a
    # redirect that changed nothing is the honest answer to one.
    def moved
      layout = @project.panel_layout
      order = layout.order.dup
      from = order.index(params[:panel].to_s)
      to = from && (params[:move] == "up" ? from - 1 : from + 1)
      order[from], order[to] = order[to], order[from] if from && to&.between?(0, order.size - 1)

      { "order" => order, "hidden" => layout.hidden }
    end

    # THE FORM SENDS THE COMPLETE PICTURE: `order` is every panel in the order they were shown, and
    # `visible` is the checked subset, so hidden is simply the difference. An unchecked checkbox
    # sends NOTHING, which is exactly why `order` is a list of hidden fields rather than something
    # derived from `visible` — without it, unchecking a box would delete the panel from the order
    # instead of hiding it.
    def chosen
      attrs = params.require(:panels).permit(order: [], visible: [])
      order = (known(attrs[:order]) + @project.panel_layout.order) & Maker::Project::PANELS
      { "order" => order, "hidden" => order - known(attrs[:visible]) }
    end

    def known(list) = Array(list).map(&:to_s) & Maker::Project::PANELS
  end
end
```

- [ ] **Step 8: the CSS.** Append at the end of `app/assets/stylesheets/pages/projects.css`, inside
      the `@layer pages { … }` block, after S4-1's quiet-panel rules:

```css
  /* --- The panel chooser (stage 4, S4-7): which panels this page shows, chosen on this page.
     Closed by default and below the panels, so it never displaces the maker's own content. A
     `summary.btn` and a `linkbtn` per move are COMPONENTS, styled in components.css and only
     qualified here (design-system rule 3). The row wraps at 375px rather than scrolling: rule 11
     is asserted by the phone sweep with this element OPEN. --- */
  .panel-chooser { margin-top: 20px; }
  .panel-chooser > summary { display: inline-block; cursor: pointer; }
  .panel-chooser-note { margin: 10px 0 6px; }
  .panel-choices { list-style: none; margin: 0; padding: 0; max-width: 420px; }
  .panel-choice { display: flex; flex-wrap: wrap; align-items: center; gap: 8px;
                  padding: 4px 0; border-bottom: 1px solid var(--line); }
  .panel-choice:last-child { border-bottom: 0; }
  .panel-choice-name { flex: 1 1 auto; display: flex; align-items: center; gap: 6px; overflow-wrap: anywhere; }
  .panel-choice-always { font: 11px/1.4 var(--font-mono); }
  .panel-choice-moves { display: flex; gap: 4px; }
  .panel-chooser-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-top: 10px; }
```

- [ ] **Step 9: the door's tests.** Create `test/integration/web/project_panels_test.rb`:

```ruby
require "test_helper"

module Web
  # STAGE 4, S4-7 (story 6.5): the panel chooser and the one door behind it. No JavaScript — the
  # whole surface is checkboxes, two button_to arrows and a Save, so every assertion here is on
  # markup a browser posts and on the row that comes back.
  class ProjectPanelsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "panels-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    # --- the markup -----------------------------------------------------------------------------

    # ASSERT THE RENDERED FIELD NAME (§14d, twice-shipped). A nested-hash POST below would pass
    # whatever the form emitted, so the name the browser will actually send is asserted here.
    test "the chooser names every panel, with the field names the door reads" do
      get project_path(@project)

      assert_select "details.panel-chooser#panels" do
        assert_select "li.panel-choice", Maker::Project::PANELS.size
        Maker::Project::PANELS.each do |key|
          assert_select "input[name=?][value=?]", "panels[order][]", key
        end
        assert_select "input[type=checkbox][name=?][value=?]", "panels[visible][]", "tasks"
        assert_select "input[type=hidden][name=?][value=?]", "panels[visible][]", "attachments",
                      "an always-shown panel carries a hidden field, not a checkbox"
        assert_select "input[type=checkbox][name=?][value=?]", "panels[visible][]", "attachments", count: 0
      end
    end

    # THE `form` ATTRIBUTE IS THE WHOLE MECHANISM (projects/_wiring's idiom): a <form> cannot
    # contain a button_to's own form, so the fields sit outside their form and point back at it.
    # Without this the checkboxes belong to no form and Save posts an empty body.
    test "every field points back at the empty checkbox form by id" do
      get project_path(@project)

      assert_select "form#panel-visibility[action=?]", project_panels_path(@project)
      assert_select "input[name=?][form=?]", "panels[order][]", "panel-visibility"
      assert_select "input[name=?][form=?]", "panels[visible][]", "panel-visibility"
      assert_select "input[type=submit][form=?]", "panel-visibility"
    end

    test "the chooser is closed until a write reopens it" do
      get project_path(@project)
      assert_select "details.panel-chooser[open]", count: 0

      get project_path(@project, panels: "open")
      assert_select "details.panel-chooser[open]", 1
    end

    test "the move buttons carry the panel and the direction as hidden inputs" do
      get project_path(@project)

      assert_select "form[action=?] input[name=move][value=up]", project_panels_path(@project)
      assert_select "form[action=?] input[name=panel][value=tasks]", project_panels_path(@project)
    end

    # --- the door -------------------------------------------------------------------------------

    test "Save writes the checked subset as visible and the rest as hidden" do
      patch project_panels_path(@project),
            params: { panels: { order: Maker::Project::PANELS,
                                visible: Maker::Project::PANELS - %w[tasks sheets] } }

      assert_redirected_to project_path(@project, panels: "open", anchor: "panels")
      assert_equal %w[tasks sheets], @project.reload.panels["hidden"]
      refute @project.panel_layout.visible?("tasks")
    end

    test "a move swaps two adjacent panels and leaves the rest alone" do
      patch project_panels_path(@project), params: { move: "up", panel: "tasks" }

      order = @project.reload.panels["order"]
      assert_equal %w[build_log tasks], order[3, 2]
      assert_equal Maker::Project::PANELS.sort, order.sort
    end

    # A HIDDEN PANEL KEEPS ITS SLOT. Without this, hiding then reordering then showing again would
    # send a panel to the end of the page for no reason the maker asked for.
    test "a move rewrites the full order, hidden panels included" do
      @project.update!(panels: { "hidden" => %w[wiring] })

      patch project_panels_path(@project), params: { move: "up", panel: "wiring" }

      assert_includes @project.reload.panels["order"], "wiring"
      assert_equal %w[wiring], @project.panels["hidden"], "a move must not change what is hidden"
    end

    test "a move off either end changes nothing and does not error" do
      patch project_panels_path(@project), params: { move: "up", panel: Maker::Project::PANELS.first }
      assert_response :redirect
      assert_equal Maker::Project::PANELS, @project.reload.panel_layout.order

      patch project_panels_path(@project), params: { move: "down", panel: Maker::Project::PANELS.last }
      assert_equal Maker::Project::PANELS, @project.reload.panel_layout.order
    end

    # THE DOOR WRITES ONLY KNOWN KEYS. Structural, not a validation: this is the guard that stops a
    # crafted request from putting a partial name in the column that `render` would then be handed.
    test "a crafted request cannot put an unknown key in the column" do
      patch project_panels_path(@project),
            params: { panels: { order: [ "attachments", "../../etc/passwd" ],
                                visible: [ "attachments", "nope" ] } }

      stored = @project.reload.panels
      assert_operator Maker::Project::PANELS.to_set, :superset?, stored["order"].to_set
      assert_operator Maker::Project::PANELS.to_set, :superset?, stored["hidden"].to_set
      get project_path(@project)
      assert_response :success
    end

    test "Reset removes the override rather than writing the preset into the row" do
      @project.update!(kind: "laser", panels: { "hidden" => [] })

      delete project_panels_path(@project)

      assert_nil @project.reload[:panels],
                 "reset must clear the column, so the project keeps following its kind"
      refute @project.panel_layout.visible?("bom"), "the laser preset is back"
    end

    test "the door is another user's 404 and a signed-out visitor's redirect" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      assert_raises(ActiveRecord::RecordNotFound) do
        patch project_panels_path(theirs), params: { move: "up", panel: "tasks" }
      end

      delete destroy_user_session_path
      patch project_panels_path(@project), params: { move: "up", panel: "tasks" }
      assert_redirected_to new_user_session_path
    end
  end
end
```

- [ ] **Step 10: `?kind=` on the index.** In `ProjectsController#index`, after the `@q = …` line:

```ruby
    # `?kind=` (stage 4, S4-7): the same whitelist-and-filter shape `@tag` uses one line up, over a
    # closed vocabulary rather than the user's own rows -- `presence_in` is what makes an unknown
    # value read as "no filter" rather than as an empty page.
    @kind = params[:kind].presence_in(Maker::Project::KINDS)
```
after `scope = scope.tagged_with(@tag) if @tag`:
```ruby
    scope = scope.where(kind: @kind) if @kind
```
and beside `@project_tags`:
```ruby
    # THE KINDS THIS USER ACTUALLY HAS, for the filter chips -- ONE query, constant in N, and the
    # same "only when there is something to filter by" rule @project_tags follows. `other` is
    # dropped because it is the column default and a chip for "everything nobody typed" filters
    # nothing useful (S4-6's own rule: badging a default is noise). Asked BEFORE the kind filter
    # narrows `scope`, or filtering by one kind would leave one chip and no way back.
    @project_kinds = current_user.maker_projects.distinct.order(:kind).pluck(:kind) - [ "other" ]
```

- [ ] **Step 11: permit the param.** In `#project_params`, add `:kind` to the `permit` list.

- [ ] **Step 12: run, expect PASS.**
      `bin/rails test test/integration/web/project_page_test.rb test/integration/web/project_panels_test.rb test/integration/web/project_attachments_test.rb test/integration/web/project_bom_test.rb test/integration/web/project_wiring_test.rb test/integration/web/project_releases_test.rb test/integration/web/project_sheets_test.rb test/integration/web/project_tasks_test.rb test/integration/web/project_repo_card_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb`

- [ ] **Step 13: mutation checks.** Five, each run and its output reported.
  (i) In `show.html.erb` change `@panel_layout.visible` to `@panel_layout.order` → the
      "a hidden panel is not rendered at all" test FAILS (the tasks panel is back).
  (ii) In `show.html.erb` change `@panel_layout.visible` to `Maker::Project::PANELS` → the
      "a stored order reorders the DOM" test FAILS on both `assert_operator`s.
  (iii) In `panels_controller.rb`'s `known`, drop `& Maker::Project::PANELS` → the
      "a crafted request cannot put an unknown key" test FAILS.
  (iv) In `#chosen`, replace `order - known(attrs[:visible])` with `[]` → the Save test FAILS
      (`Expected: ["tasks", "sheets"] Actual: []`).
  (v) In `#show`, change `bom_shown` to `true` → **nothing goes red yet**; that is Task E's
      query-count guard, and it is noted here so the implementer does not conclude the skip is
      unguarded. Restore and leave it to E.
  Restore each with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after (i) and (v), which
  are equal-length edits.

- [ ] **Step 14: commit.**

```bash
git add app/controllers/projects_controller.rb app/controllers/projects/panels_controller.rb \
        app/views/projects/show.html.erb app/views/projects/_panel_chooser.html.erb \
        config/routes.rb app/assets/stylesheets/pages/projects.css \
        test/integration/web/project_page_test.rb test/integration/web/project_panels_test.rb
git commit -m "The project page's panels are a list the maker can reorder and hide, and a hidden one costs no queries"
```

---

### Task D: the form, the cards, the filter and the visitor

Starts after C has committed (it reads `@kind`/`@project_kinds` and needs `project_params` to
permit `:kind`).

**Files:**
- Modify: `app/views/projects/_form.html.erb`, `_card.html.erb`, `index.html.erb`,
  `app/views/home/_project_hero.html.erb`, `app/services/maker/public_project.rb`,
  and the public page body — **re-anchor**: `app/views/public/projects/_page.html.erb` if S4-4
  has merged, otherwise `app/views/public/projects/show.html.erb`, whose `.project-panels` block
  is identical because S4-4's Task D step 3 is a pure move.
- Test: `test/integration/web/projects_flow_test.rb`, `test/integration/web/home_test.rb`,
  `test/integration/web/public_project_test.rb`

- [ ] **Step 1: the failing tests.** Append to `test/integration/web/projects_flow_test.rb` (copy
      its own `sign_in`, which returns the user):

```ruby
    # STAGE 4, S4-7 (story 6.5): the type is chosen here, and ASSERTED ON THE RENDERED FIELD NAME
    # (§14d) rather than through a nested-hash POST, which would pass whatever the form emitted.
    test "the edit form offers the project type under the name the controller permits" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp")

      get edit_project_path(project)

      assert_select "form.project-form select[name=?]", "project[kind]"
      assert_select "form.project-form select[name='project[kind]'] option[value=laser]",
                    text: "Laser cutting"
      assert_select "form.project-form select[name='project[kind]'] option[selected=selected][value=other]"
    end

    test "saving the type changes the page's panels" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp")

      patch project_path(project), params: { project: { name: "Desk Lamp", kind: "laser" } }

      assert_equal "laser", project.reload.kind
      get project_path(project)
      assert_select "section.bom-panel", count: 0, "the laser preset hides the BOM"
    end

    # THE CHIPS ARE DERIVED FROM WHAT THE USER HAS, and `other` is dropped because it is the column
    # default — a chip for "everything nobody typed" filters nothing.
    test "the index filters by kind, with chips for the kinds this user actually has" do
      user = sign_in
      user.maker_projects.create!(name: "Cut Box", kind: "laser")
      user.maker_projects.create!(name: "Bracket", kind: "print")
      user.maker_projects.create!(name: "Untyped")

      get projects_path
      assert_select ".projects-toolbar a.chip", text: "Laser cutting"
      assert_select ".projects-toolbar a.chip", text: "3D printing"
      assert_select ".projects-toolbar a.chip", text: "Other", count: 0

      get projects_path(kind: "laser")
      assert_select ".project-card .project-name", text: "Cut Box"
      assert_select ".project-card .project-name", text: "Bracket", count: 0
      assert_select ".projects-toolbar a.chip.active", text: "Laser cutting"
    end

    test "an unknown kind filters nothing rather than emptying the page" do
      user = sign_in
      user.maker_projects.create!(name: "Cut Box", kind: "laser")

      get projects_path(kind: "wormhole")

      assert_select ".project-card .project-name", text: "Cut Box"
    end

    # BADGE A NON-DEFAULT KIND ONLY (S4-6's own rule: a field you can set and never see is worse
    # than no field, and badging a default is noise).
    test "a card badges its kind, and an untyped project's card carries none" do
      user = sign_in
      user.maker_projects.create!(name: "Cut Box", kind: "laser")
      user.maker_projects.create!(name: "Untyped")

      get projects_path

      assert_select ".project-tile .badge.project-kind", 1
      assert_select ".project-tile .badge.project-kind", text: "Laser cutting"
    end
```

Append to `test/integration/web/home_test.rb` (copy its own sign-in and current-project idiom):

```ruby
    # STAGE 4, S4-7: Home's hero says what kind of project it is holding, on the same rule the
    # cards follow — a non-default kind only.
    test "the current-project hero badges a typed project and says nothing for an untyped one" do
      @project.update!(kind: "electronics")
      get root_path
      assert_select ".home-hero .panel-head .badge.project-kind", text: "Electronics & firmware"

      @project.update!(kind: "other")
      get root_path
      assert_select ".home-hero .badge.project-kind", count: 0
    end
```

Append to `test/integration/web/public_project_test.rb` (copy its own published-project fixture):

```ruby
    # STAGE 4, S4-7 (story 6.5): THE VISITOR SEES THE PAGE THE MAKER ARRANGED. One layout, read off
    # the project through Maker::PublicProject, so the two pages cannot disagree about what is
    # hidden — a maker who hid Wiring did not hide it only from themselves.
    test "a hidden panel is hidden from a visitor too" do
      @project.connections.create!(user: @owner, from_label: "Driver", to_label: "Stepper")

      get public_project_path(@owner.handle, @project.slug)
      assert_select "section.wiring-panel", 1

      @project.update!(panels: { "hidden" => %w[wiring] })
      get public_project_path(@owner.handle, @project.slug)
      assert_select "section.wiring-panel", count: 0
    end

    test "a stored order reorders the visitor's page as well" do
      @project.update!(panels: { "order" => %w[build_log attachments] })

      get public_project_path(@owner.handle, @project.slug)

      panels = css_select("div.project-panels > section.panel").map { |s| s["class"] }
      assert_operator panels.index { |c| c.include?("build-log-panel") }, :<,
                      panels.index { |c| c.include?("attachments-panel") }
    end

    # A PRIVATE-ONLY PANEL HAS NO PUBLIC FACE, AND THE MAP IS THE WHOLE DEFINITION OF THAT. Tasks,
    # Sheets and Publish are absent from a visitor's page today and must stay absent whatever the
    # order says — a maker who moved Tasks to the top must not publish their task list.
    test "tasks, sheets and publish never reach a visitor, whatever the order says" do
      @project.tasks.create!(user: @owner, title: "cut")
      @project.sheets.create!(user: @owner, name: "Cut list")
      @project.update!(panels: { "order" => %w[tasks sheets publish] })

      get public_project_path(@owner.handle, @project.slug)

      assert_response :success
      assert_select "section.tasks-panel", count: 0
      assert_select "section.sheets-panel", count: 0
      assert_select "section.publish-panel", count: 0
    end

    # AN EMPTY PANEL IS STILL OMITTED for a visitor — the public page's own rule (its header says
    # why: an empty state invites someone to add the first one, which is what a visitor cannot do).
    # The layout decides whether a panel is RENDERED; each public partial still decides whether it
    # has anything to render. Two questions here as well.
    test "a visible panel with nothing in it is still omitted" do
      get public_project_path(@owner.handle, @project.slug)

      assert_select "section.releases-panel", count: 0
    end
```

- [ ] **Step 2: run, expect FAIL.**
      `bin/rails test test/integration/web/projects_flow_test.rb test/integration/web/home_test.rb test/integration/web/public_project_test.rb`

- [ ] **Step 3: the edit form.** In `app/views/projects/_form.html.erb`, after the Tags label and
      before whatever S4-2/S4-4 left in the Visibility/License slot (re-anchor on
      `<span>Tags</span>`'s closing `</label>`):

```erb
  <%#
    THE PROJECT'S TYPE (stage 4, S4-7; decision D4; story 6.5). Suggested from the folder when the
    app created the project and changeable here — the ONE place it changes after creation, because
    nothing re-derives it (a sweep that re-suggested would silently rearrange a page the maker may
    have arranged themselves, and nothing could tell the two apart).
    IT PRESETS, IT DOES NOT OVERWRITE: an explicit show/hide/reorder is stored separately in
    `panels` and keeps winning, so changing the type here rearranges only the panels the maker has
    not spoken about. The chooser at the foot of the project page is where those live.
  %>
  <label class="field">
    <span>Type</span>
    <%= f.select :kind,
                 options_for_select(Maker::Project::KINDS.map { |k| [ Maker::ProjectKind.label(k), k ] },
                                    project.kind) %>
    <span class="field-hint muted">Presets which panels this project's page shows, and which file
      its hero prefers.</span>
  </label>
```

- [ ] **Step 4: the card.** In `app/views/projects/_card.html.erb`, after the
      `<span class="project-name">…</span>` line and before the closing `<% end %>` of the
      `link_to`:

```erb
    <%# THE KIND, WHERE THE PROJECT IS LISTED (stage 4, S4-7). A NON-DEFAULT kind only: `other` is
        the column default, and badging a default is noise — the same rule the archived badge and
        S4-6's status badge follow. `.badge` is a component; this adds a qualifier, never a
        redeclaration (design-system rule 3). %>
    <% unless project.kind == Maker::ProjectKind::DEFAULT %>
      <span class="badge project-kind"><%= Maker::ProjectKind.label(project.kind) %></span>
    <% end %>
```

- [ ] **Step 5: the chips.** In `app/views/projects/index.html.erb`, replace the `if @project_tags.any?`
      toolbar block's condition and add a second chip row inside it:

```erb
<% if @project_tags.any? || @project_kinds.any? %>
  <div class="toolbar projects-toolbar">
    <% if @project_kinds.any? %>
      <%# TYPE CHIPS (stage 4, S4-7). Their own row beside the tag chips rather than mixed into
          them: a tag is the maker's word and a kind is one of six the app knows, and one "All"
          that cleared both would make each filter unreachable while the other was on. Each link
          keeps every OTHER filter in the url for the same reason. %>
      <span class="chips">
        <%= link_to "All types", projects_path(tag: @tag, archived: (@archived_view ? 1 : nil)),
                    class: "filter chip#{' active' if @kind.blank?}" %>
        <% @project_kinds.each do |k| %>
          <%= link_to Maker::ProjectKind.label(k),
                      projects_path(kind: k, tag: @tag, archived: (@archived_view ? 1 : nil)),
                      class: "filter chip#{' active' if @kind == k}" %>
        <% end %>
      </span>
    <% end %>
    <% if @project_tags.any? %>
      … the existing tag chips block, unchanged except that each `projects_path(...)` also carries
      `kind: @kind` so a tag click does not silently clear the type filter …
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 6: Home's hero.** In `app/views/home/_project_hero.html.erb`, inside `.panel-head`,
      after the `<h2>` line:

```erb
      <%# The same non-default-only rule the index cards follow (stage 4, S4-7). %>
      <% unless @project.kind == Maker::ProjectKind::DEFAULT %>
        <span class="badge project-kind"><%= Maker::ProjectKind.label(@project.kind) %></span>
      <% end %>
```

- [ ] **Step 7: the public reader.** In `app/services/maker/public_project.rb`, beside `#sections`:

```ruby
    # THE OWNER'S OWN PANEL LAYOUT, HONOURED FOR A VISITOR (stage 4, S4-7; story 6.5). Delegated
    # rather than recomputed, so the maker's page and a visitor's cannot disagree about what is
    # hidden — the same argument #photo_rows makes for delegating to Maker::ProjectPhotos. Reads two
    # columns off a row this object already holds: no query.
    #
    # WHICH OF THESE HAVE A PUBLIC FACE IS THE TEMPLATE'S QUESTION, not this one's — see
    # public/projects/_page.html.erb's partial map, whose absent keys (tasks, sheets, publish) are
    # the whole definition of "private only".
    def visible_panels = project.panel_layout.visible
```

- [ ] **Step 8: the public page.** In `app/views/public/projects/_page.html.erb` (or
      `show.html.erb` — re-anchor), replace the whole `<div class="project-panels"> … </div>` block
      with:

```erb
<%#
  THE PANELS, IN THE OWNER'S OWN ORDER (stage 4, S4-7; story 6.5). The visitor sees the page the
  maker arranged: a panel they hid is hidden here too, and a panel they moved is moved here too --
  one layout, read off the project through Maker::PublicProject#visible_panels.

  THE MAP IS THE WHOLE DEFINITION OF "HAS A PUBLIC FACE". `tasks`, `sheets` and `publish` are
  absent from it and are therefore absent from a visitor's page WHATEVER the order says, which is
  exactly what they were before this loop existed -- there is no second list to keep in step, and a
  maker who drags Tasks to the top does not publish their task list.

  WIRING IS THE ONE SPECIAL CASE and it is not new: the shared projects/_wiring partial is what the
  visitor gets, with `editable: false`, and it has always been wrapped in a check for any
  connections at all -- read-only, its empty state is a heading and nothing else, which is a panel
  rather than the absence the rest of this page uses.

  AN EMPTY PANEL IS STILL OMITTED. Each partial below decides that for itself, exactly as before:
  the layout decides whether a panel is RENDERED, the partial decides whether it has anything to
  render. Two questions, the same pair the private page keeps as hidden versus quiet.
%>
<% public_panels = { "attachments" => "public/projects/files",
                     "photos"      => "public/projects/photos",
                     "schematics"  => "public/projects/schematics",
                     "build_log"   => "public/projects/build_log",
                     "bom"         => "public/projects/bom",
                     "releases"    => "public/projects/releases" } %>
<div class="project-panels">
  <% pub.visible_panels.each do |key| %>
    <% if key == "wiring" %>
      <% if pub.connections.any? %>
        <%= render "projects/wiring", project: project, connections: pub.connections, editable: false %>
      <% end %>
    <% elsif (partial = public_panels[key]) %>
      <%= render partial, pub: pub %>
    <% end %>
  <% end %>
  <% pub.repo_cards.each_value do |card| %>
    <%= render "repo_card", card: card %>
  <% end %>
</div>
```

**If S4-4 has not merged** the local is `@pub`, not `pub`, and `project` is `@project` — take the
committed file as the base and change only the loop.

- [ ] **Step 9: run, expect PASS.**
      `bin/rails test test/integration/web/projects_flow_test.rb test/integration/web/home_test.rb test/integration/web/public_project_test.rb test/integration/web/public_bundle_test.rb test/integration/web/public_feed_test.rb test/integration/web/public_explore_test.rb test/integration/web/gerber_preview_test.rb test/integration/web/project_publishing_form_test.rb`
      → 0 failures. **`public_project_test.rb`'s existing assertions must not need editing**: the
      loop over `other`'s layout renders the same six partials in the same order the hard-coded
      list did. If one needs changing, the order is wrong — fix the order, not the assertion.

- [ ] **Step 10: mutation checks.** Four, run and reported.
  (i) In `_page.html.erb` change `pub.visible_panels` to `Maker::Project::PANELS` → the
      "a hidden panel is hidden from a visitor too" test FAILS.
  (ii) In `_page.html.erb` add `"tasks" => "public/projects/build_log"` to `public_panels` → the
      "tasks, sheets and publish never reach a visitor" test FAILS (a second build log renders).
      Restore — this is the mutation that proves the absent-key rule is load-bearing rather than a
      coincidence of which partials happen to exist.
  (iii) In `_card.html.erb` drop the `unless project.kind == …DEFAULT` guard → the card test FAILS
      on `count: 1` (the untyped project badges "Other" too).
  (iv) In `#index`, change `params[:kind].presence_in(Maker::Project::KINDS)` to
      `params[:kind].presence` → the "an unknown kind filters nothing" test FAILS (the page empties).
  Restore each; clear `tmp/cache/bootsnap*` after (i) and (iv).

- [ ] **Step 11: commit.**

```bash
git add app/views/projects/_form.html.erb app/views/projects/_card.html.erb app/views/projects/index.html.erb \
        app/views/home/_project_hero.html.erb app/services/maker/public_project.rb \
        app/views/public/projects/_page.html.erb \
        test/integration/web/projects_flow_test.rb test/integration/web/home_test.rb \
        test/integration/web/public_project_test.rb
git commit -m "A project says what kind it is on its cards and its form, and a visitor sees the page the maker arranged"
```

---

### Task E: the cross-cutting guards

Starts after D has committed. These four files are single files C and D would otherwise both edit.

**Files:**
- Modify: `test/integration/web/page_query_budget_test.rb`,
  `test/integration/web/template_hygiene_test.rb`, `test/system/shell_test.rb`
- Verify: `test/css_hygiene_test.rb` (expect no edit)

- [ ] **Step 1: the query budgets still hold, unchanged.**
      `bin/rails test test/integration/web/page_query_budget_test.rb` → PASS with **no edit**.
      Both `projects#show` and `public projects#show` seed projects of kind `other`, whose preset
      is today's page, so both measure exactly the code path they measured before; `projects_path`
      gains one constant query (`@project_kinds`) and the assertion is constancy, never a literal
      (§14e). **If any of the three goes red, the loop grew a per-panel query — find it, do not
      relax the assertion.**

- [ ] **Step 2: the skip has a guard of its own.** Append to `page_query_budget_test.rb`, beside
      the `projects#show` test (it can use that file's own `count_queries` and `node!`):

```ruby
    # STAGE 4, S4-7: A HIDDEN PANEL COSTS NO QUERIES. `assert_constant_queries` cannot see this —
    # it compares one page against itself at two sizes, and both sizes would pay the same skipped
    # loads — so the guard is a comparison between two LAYOUTS of one page at one size. A strict
    # inequality rather than a literal for the same reason every other budget here avoids one: the
    # counts differ per LIBRARY_BACKEND (§14e), and what is asserted is that the skip HAPPENS.
    #
    # THREE PANELS AND NO MORE. @tasks and @sheets are counted by the page's stats line and
    # @entries is read by Maker::ProjectPhotos, so skipping any of those three would change a
    # surface other than its own panel — ProjectsController#show says so at each site.
    test "hiding bom, wiring and releases skips their controller loads" do
      project = @user.maker_projects.create!(name: "Skippable", status: "active")
      project_folder_rows!(@user, project)
      bom = project.boms.create!(user: @user)
      3.times do |i|
        bom.lines.create!(user: @user, part_name: "part #{i}", quantity: 1, unit: "each")
        project.connections.create!(user: @user, from_label: "a#{i}", to_label: "b#{i}")
        release = project.releases.create!(user: @user, version: "v#{i}", published_at: Time.current)
        node!("rel-#{i}", "rel-#{i}.stl")
        release.files.create!(user: @user, node_id: "rel-#{i}", name: "rel-#{i}.stl",
                              path: "rel-#{i}.stl", content_token: "h-rel-#{i}", size: 1)
      end

      get project_path(project)
      shown = count_queries { get project_path(project) }

      project.update!(panels: { "hidden" => %w[bom wiring releases] })
      get project_path(project)
      hidden = count_queries { get project_path(project) }

      assert_operator hidden, :<, shown,
                      "a hidden panel still paid for its loads: #{hidden} queries hidden against " \
                      "#{shown} shown. ProjectsController#show gates @bom/@bom_lines/@items/" \
                      "@suppliers, @releases/@release_repos and @connections on @panel_layout."
    end
```

  **Mutation:** in `ProjectsController#show`, change `bom_shown = @panel_layout.visible?("bom")` to
  `bom_shown = true` → this test FAILS (the two counts converge). Restore, clear
  `tmp/cache/bootsnap*`, re-run → PASS. Report both. **This is the guard Task C step 13(v) deferred
  here.**

- [ ] **Step 3: the template sweep renders the chooser and every panel.** In
      `template_hygiene_test.rb`, add one line to the fixture's comment block beside `@project`
      (re-anchor on the `@project.update!(visibility: "public", license: …)` line):

```ruby
      # STAGE 4, S4-7: @project's `kind` STAYS `other`, whose preset hides nothing and reorders
      # nothing — which is what keeps this sweep rendering every panel partial through the loop in
      # projects/show.html.erb. Setting a kind here, or a `panels` override, would hide panels from
      # the only sweep that can see a leaked comment in them, and the coverage assertion below
      # would report them as uncovered rather than as hidden. projects/_panel_chooser renders on
      # "project detail" either way.
```

  Run `bin/rails test test/integration/web/template_hygiene_test.rb` → PASS, with
  `projects/_panel_chooser.html.erb` in the rendered set. **Mutation:** set
  `@project.update!(kind: "laser")` in the fixture → the coverage assertion FAILS, naming
  `projects/_bom.html.erb`, `_wiring.html.erb`, `_releases.html.erb` and `_sheets.html.erb` as
  rendered by no page. Restore; PASS. Report both — this is what proves the comment above is a
  live constraint rather than a note.

- [ ] **Step 4: the phone sweep opens the chooser.** In `test/system/shell_test.rb`, beside
      `launched_gerber` and `opened_repo`:

```ruby
      # STAGE 4, S4-7: the chooser is a row of ten panels with a checkbox and two arrows each,
      # closed by default — so a sweep that only VISITED this page would measure a `display: none`
      # subtree and say nothing about the one layout on it most likely to overflow at 375px. The
      # flag is this file's own rule for a branch gated on a path match: absence must be a failure.
      opened_panels = false
```
      inside the `if path == project_path(project)` branch, after the existing hero/photos
      assertions:
```ruby
          find("details.panel-chooser > summary").click
          assert_selector "li.panel-choice", minimum: 1
          opened_panels = true
```
      and after the loop, beside the two existing asserts:
```ruby
      assert opened_panels, "the sweep never opened the panel chooser, so its overflow check measured a closed <details>"
```

  Run `bin/rails test test/system/shell_test.rb` → PASS (no page scrolls sideways at 375px with the
  chooser open). **Mutation:** delete `flex-wrap: wrap` from `.panel-choice` in
  `pages/projects.css` and re-run. **Report what happens either way** — if it goes red, the wrap is
  load-bearing and the sweep covers it; if it stays green, say so in the commit message, because
  that is the same honest claim this file already makes about the public file table's column drops
  ("READABILITY, not overflow safety"). Restore.

- [ ] **Step 5: css hygiene, expect no edit.** `bin/rails test test/css_hygiene_test.rb` → PASS.
      Everything Task C added is a page modifier under `pages/`; `.badge`, `.btn`, `.linkbtn` and
      `.chip` are components, only qualified, never redeclared (design-system rule 3). **If this is
      red, a bare component selector reached `pages/projects.css` — qualify it, never move the
      rule into `components.css`.**

- [ ] **Step 6: the full local gates.**
      `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` → green.
      Read the three legs' run counts (`test`, `test-s3`, `test-chunk-remote`) and confirm they are
      identical; a ±2 assertion flap is `tinkerex#131`, anything structural is a test depending on
      the ambient `LIBRARY_BACKEND` and is a bug.

- [ ] **Step 7: commit.**

```bash
git add test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb \
        test/system/shell_test.rb
git commit -m "A hidden panel is asserted to cost nothing, and the sweeps see the chooser and every panel"
```

---

### Task F: close-out

- [ ] **Step 1: re-tag the stories** in `docs/user-stories.md`, with the new evidence in the last
      column, and update the Coverage table's counts.
  - **6.1** stays `rough` — **S4-7:** a laser project's page no longer carries BOM, Wiring,
    Releases or Sheets (`Maker::ProjectKind::PRESETS`), and the kind is suggested from the folder's
    own files. Still rough: which file comes first *inside* the Files panel is still name order
    (`project_folder_listing.rb`), which is 6.4's other half.
  - **6.2** stays `rough` — **S4-7:** an electronics project lifts Schematics and Wiring above the
    build log (story 6.2's own list), and a firmware repo is suggested `electronics` from its `.git`
    marker and its sources. Still rough: no board render on the project page; schematics are
    KiCad-only.
  - **6.3** stays `rough` — **S4-7:** a `print` project's hero prefers a model over a photo
    (`Maker::ProjectKind.hero_roles`), so the model is the hero without anyone choosing one. Still
    rough: print history lives on Models.
  - **6.4** → `rough` (was `missing`) — **S4-7:** the kind picks the hero's preferred role among
    the project's attachments, and a chosen `cover_node_id` still wins over it. Still missing:
    pinning a file to the top of the Files panel.
  - **6.5** → `works` — **S4-7:** `kind` with six values suggested from the folder and editable on
    the form; per-kind presets for order and visibility; per-project show/hide/reorder with no
    JavaScript (`projects/_panel_chooser`, `Projects::PanelsController`); Reset to the kind's
    defaults; and the visitor's page honours the same layout.

- [ ] **Step 2: the overview.** In `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`:
  - mark the S4-7 row **landed** with the PR number;
  - under **"The quiet-panel contract (S4-1 creates; S4-7 reads)"**, add the other half now that it
    exists — that `Maker::Project::PANELS` is the canonical key list, that
    `Maker::Project#panel_layout` is the one reader both pages use, that `ALWAYS` names the three
    panels no override may hide, and that a new panel must be added to `PANELS` or it renders for
    nobody;
  - correct the S4-7 territory line: there is **no `panels` Stimulus controller** (amendment 3),
    the chooser is `projects/_panel_chooser.html.erb` on the project page with
    `Projects::PanelsController` behind it, and the slice also touches
    `Maker::PublicProject`/`public/projects/_page.html.erb` and `Maker::ProjectDiscovery`, none of
    which that row named.

- [ ] **Step 3: hand on the two conditional obligations (amendments 8 and 9).** Whichever applied:
  - if `Projects::AdoptionsController` did not exist, write into the overview's **S4-6** territory
    section that adoption must pass
    `kind: Maker::ProjectKind.suggest_for(user: current_user, folder_node_id: node.node_id)` in its
    `create!`, with one test;
  - if `projects/_publish.html.erb` did not exist, write into the overview's **S4-4** territory
    section that S4-4 must add `publish` to `Maker::Project::PANELS`, `PANEL_LABELS` and
    `Maker::ProjectKind::ALWAYS` and render it **through the loop** in `show.html.erb`, never as a
    tenth `render` beneath it.
  If neither applied, say so in the PR body rather than silently.

- [ ] **Step 4: spec §7's Stimulus line.** `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md`
      §7 says "a new `copy` controller (S4-3) or `panels` controller (S4-7) needs no test edit but
      must exist before any template names it". **Do not edit the spec** — it is the design of
      record and the sentence was true of the design. Record the divergence in the PR body and in
      the arc: S4-7 ships no `panels` controller because the chooser needs no JavaScript, and §14d's
      rule points the safe way (a `data-controller` resolving to nothing is a silent no-op, so the
      answer is to name none).

- [ ] **Step 5: the gates.** `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`
      green; the three legs' run counts identical.

- [ ] **Step 6: commit, push, PR, record.**
      `git commit -m "S4-7 close-out: the stories re-tagged, the overview updated"`; `/finish-branch`;
      then `bin/log arc --from-pr <n>`. The PR body states what was verified and what was not —
      in particular, which of the two conditional obligations applied, and whether the phone
      sweep's `flex-wrap` mutation went red.

---

## Self-review against the spec (§2's D4, §4, §5's S4-7 row, §7)

| spec / prompt item | where it lands | mutation that proves it |
|---|---|---|
| `kind` ∈ laser, print, cnc, electronics, mixed, other; string, NOT NULL, default `other` | A steps 2, 6 | A 12: `kind` validation — the inclusion test |
| `panels` JSON column | A step 2 | A 12(ii): drop the filter, the garbage test reds |
| Both defaults reproduce today's page (spec §4) | A steps 2, 9 (`PRESETS["other"]`, `hero_roles("other")`) | A 12(iv) and A's "other reproduces today's page exactly" + `project_cover_test.rb` unchanged |
| `Maker::ProjectKind.suggest(listing)` from the folder's role mix, table-driven test | A steps 4, 9 (`FAMILIES`, `REPO_WEIGHT`, `MIXED_SHARE`) | B step 7: `kind: "other"` — three table rows red |
| Called on discovery | B steps 3, 4 | B step 7 |
| Called on adoption (S4-6) | B step 6, conditional (amendment 8) | the adoption test, if it applies |
| Offered as the default on the New form (an empty folder suggests `other`) | A step 6 (column default) + D step 3 | D 10: the form field-name assertion |
| Editable on the edit form, plain-language labels | D step 3 | D's "saving the type changes the page's panels" |
| Presets: panel order and default visibility per kind, tabulated | the table above; A step 9 `PRESETS` | A 12(iii); A's laser/electronics preset test |
| Files, Photos and Publish always rendered | A step 9 `ALWAYS` | A 12(iii) and C's "Files stays on the page" |
| Hero's preferred role per kind; stored cover still wins | A step 8 + `HERO_ROLES` | A 12(iv) |
| `panels` overrides `{order, hidden}` validated against `PANELS` | A step 9 `layout_for`/`known`; C step 7 `known` | A 12(ii); C 13(iii) |
| `#panel_layout` merges preset ← overrides; `#visible_panels` in order | A step 7 | A's "hidden set REPLACES" and "order wins" tests |
| `show.html.erb` becomes ONE loop; ivars kept, locals map for the three partials that take them | C step 4 | C 13(i) and 13(ii) |
| The quiet contract survives: a rendered empty panel is still quiet | C step 1's "hidden and quiet are different states" | that test's second half |
| Chooser: no JS, Show checkbox + Up/Down `button_to` + Reset; rendered field names asserted | C steps 5, 7, 9 | C 13(iv); the `form=` wiring test |
| Public page honours the layout; hidden stays hidden; order follows; empty still omitted | D steps 7, 8 | D 10(i) and 10(ii) |
| Private-only panels never reach a visitor | D step 8's absent keys | D 10(ii) |
| Cards and Home hero show kind; `/projects?kind=` filters | D steps 4, 5, 6, 10 | D 10(iii), 10(iv) |
| Query budgets stay constant; hidden panels skip only safe loads | C step 3; E steps 1, 2 | E step 2's `bom_shown = true` |
| The template sweep renders every panel through the loop | E step 3 | E step 3's `kind: "laser"` mutation |
| Two new columns' obligations: no index, and why | amendment 12; A steps 2, 13 | — (a stated argument; `schema_map_test.rb` is what goes red if the map is stale) |
| Port-free fixtures; three legs identical | every test above uses `project_folder_rows!`; E step 6 | — |
| Migration in dev and test, `db/schema.rb` committed | A step 3 | `schema_map_test.rb` |
| Stories 6.1–6.5 re-tagged in the same PR | F step 1 | — |

## Open questions the implementer must not decide alone

1. **Is `sheets` hidden for `print` and `laser` the right call?** The table above hides it for
   laser, print and electronics and keeps it for cnc and mixed, on the evidence that real use is
   **zero sheets across nine projects** and that story 6.1 does not name it among what should come
   first. That is a defensible default and it is also the one line in the preset table that is a
   judgement about a maker's habits rather than about a file format. If a reviewer disagrees, it is
   a one-word edit in `PRESETS` plus one line in the table above and one in
   `project_kind_test.rb` — but **make the change in review, not in the middle of Task C**, because
   `template_hygiene_test.rb`'s fixture and `project_page_test.rb`'s order assertions both read the
   preset table.

2. **`REPO_WEIGHT = 2` and `MIXED_SHARE = 0.5` are calibrated against three real repositories and a
   seeded library, not against the live share.** Both are pinned by table rows in
   `project_kind_test.rb`, so changing either is loud — but neither has been run over the real
   3,232-file library. **A read-only probe of the live share deployment** (`Maker::ProjectKind
   .suggest_for` over each of the nine real projects' folders, printing the answer and the family
   counts, writing nothing) is worth doing before this merges, and is the kind of measurement §14e
   asks for rather than reasoning. It cannot be done from CI; it needs the deploy box.

3. **Whether the chooser belongs on the project page at all** is amendment 4, and the argument
   against it is S4-4's decision 8 (a settings surface must not take prime real estate). This plan
   answers with "closed `<details>`, below the panels, and reordering is a repeated action whose
   result you have to see" — but if a reviewer wants it on the edit form it is a move of one
   `render` plus a redirect target, and it should be settled **before Task C starts**, not after
   `project_panels_test.rb` has pinned the markup.

4. **A partial unique index on `(user_id, folder_node_id)`** is S4-6's open question 1, and this
   slice touches the same neighbourhood: a folder adopted twice would now also be *suggested* twice.
   Not this slice's to fix, and named here only so a reviewer does not read the `kind:` line in
   `Maker::ProjectDiscovery` as a new exposure. It is not: the duplicate is the pre-existing race.

5. **Nothing re-suggests a kind after creation** (amendment 7), so a folder that was empty when it
   was discovered and is full a week later stays `other` for ever unless its maker says otherwise.
   That is deliberate, and it is also the most likely thing a maker will report as a bug. If a later
   slice wants a "this folder looks like a laser project — switch?" prompt on the page, it should be
   a **prompt**, never a write: the moment a sweep rearranges a page nobody asked it to, there is no
   way to tell "the preset moved" from "I moved it", which is precisely why `panels` is a separate
   column from `kind`.
