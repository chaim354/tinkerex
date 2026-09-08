# Stage 4, S4-6: a project can live anywhere, and creation says what it did — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S4-6 of `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (§5's S4-6 row, decision **D1**). A folder **anywhere** in the library becomes a project by one action that moves nothing; the New project form gains a **status** select and a **make current** checkbox and its flash names the folder it minted (or names the error class when it could not); `Maker::ProjectDiscovery` stamps `discovered_at` and reports what it created, `ProjectsController#show` stamps `opened_at`, and a **New** badge sits on an auto-created project until its owner opens it; **"Not a project"** becomes an explicit, named action beside Archive; and **every** current-project switch says what it did.

**Stories moved:** 1.1, 1.2, 1.3, 1.5 (the feedback half), 1.6 (the "done is a state I can set" half), 4.5, 4.7.

**Architecture:** Adoption is a **door, not a sweep** — `Projects::AdoptionsController#create` takes one live directory node, refuses seven ways, and writes ONE `maker_projects` row whose `folder_node_id` points at that node. Nothing else changes: `Maker::ProjectFolderListing` already resolves the folder from `folder_node_id` through the `LibraryTree` (`project_folder_listing.rb:105-107`), `Maker::ProjectIntake#live_folder` already reads the same column (`project_intake.rb:442-445`) and `#place` already resolves the destination **under the folder's own node** (`project_intake.rb:753-756`), and `Project#ensure_library_folder!` is a **no-op** whenever that node is live (`project.rb:145-148`) — so a folder outside `Projects/` needs no new code path anywhere. Discovery keeps every rule in `docs/invariants/project-intake.md`; the two doors share one name rule instead of two copies. The two new columns are read off rows the pages already load, so no page grows a query.

**Tech Stack:** Rails 8, Hotwire (no new Stimulus controller, no new JS), Minitest, one migration, `page_query_budget_test.rb`, `template_hygiene_test.rb`, `css_hygiene_test.rb`, `schema_map_test.rb`.

---

## Amendments (decisions taken while writing this plan) — these override the prompt and the spec where they differ

1. **S4-2 IS A HARD PREREQUISITE, not a parallel sibling.** The overview says S4-2 and S4-6 "may run in any order"; that is no longer true. Adoption creates its project with **`autofile: false`** (amendment 4), which is S4-2's column. If `maker_projects.autofile` does not exist when you start, **stop and land S4-2 first** — do **not** add the column here. Two migrations creating one column is exactly the collision this plan exists to avoid, and S4-2's Task C owns it.

2. **Home does NOT get "Make this folder a project"; the Files page's folder view is the only door.** The spec's S4-6 row says "on the Files page and Home". Home has no folder on it: `home/index.html.erb:14-23` renders `projects/_card` over `@recent_projects` and `home/_project_hero.html.erb` renders the current **project**. There is nothing there to adopt, and inventing a folder picker on Home would be a second browsing surface beside the one the Files page already is. Home is not untouched by this slice — it renders the same `projects/_card` and therefore gets the **New** badge, which is the other half of the same story (1.1's "no new marker"). Recorded here rather than silently dropped.

3. **`make_current` is `check_box_tag`, not `f.check_box`.** `f.check_box :make_current` calls `project.make_current`, which does not exist, so it would need an `attr_accessor` on `Maker::Project` — a model attribute invented for one form. `_form.html.erb` already carries the precedent for exactly this shape: `check_box_tag "project[cover_clear]", "1", false` (`_form.html.erb:85`), stripped in `project_params` rather than permitted (`projects_controller.rb:399-402`). Follow it. `check_box_tag` emits **no hidden "0" companion**, and that is correct here rather than a gap: absent means "no", the box is offered **only on `new`**, and there is no stored attribute an unchecked box has to clear. (§14d's hidden-field rule binds on `f.check_box` against a persisted column — S4-2's `autofile` is that case and keeps its `f.check_box`.)

4. **An adopted project is created with `autofile: false`.** D1's promise is "my NAS layout stays mine" (story 1.3). A folder under `Projects/` is inside the app's own tree, where filing is the contract; a folder in `designs/` is the maker's own layout, and saying "this is a project" is a statement about what it **is**, not a request to rearrange it. Without this, adopting `designs/tray` re-files `tray.svg` into `design/` and `notes.md` into `docs/` within fifteen minutes, unasked and unattended — the fight-the-user failure §14f exists to prevent, arriving through a new door. The flash says so and links the switch S4-2 puts on the edit form. **Discovery is unchanged** and keeps the `true` default: a folder the maker put under `Projects/` asked for the app's filing by being there.

5. **The scan button reports discovery on `chunk_remote` only, and it runs the JOB, not the service.** `Projects::ScansController#pull_and_file` gains `Maker::ProjectDiscoveryJob.perform_now`, which is the idiom `Library::ScanJob#discover_projects` already uses (`scan_job.rb:233`) and is what carries `#chain_intake` — the direct service call would adopt a folder and leave its files unswept for a tick. On share/s3 the door **enqueues and stops** (§14f's race), so what discovery created is not knowable in-request; the **New badge is the surface there**, on every backend, including for the unattended 15-minute sweep, which is how discovery actually runs. **Known residual:** `limits_concurrency` engages at enqueue only, so this call sits outside the semaphore and can race the recurring `sweep_all!` tick, minting two projects for one folder. That exposure is the one `Library::ScanJob`'s own `perform_now` already has on share/s3; here it is additionally bounded by the door's `rate_limit to: 3, within: 1.minute, by: current_user.id` (`scans_controller.rb:33`). The durable fix is a partial unique index on `(user_id, folder_node_id)` — **open question 1**, not this slice.

6. **The project page badges a non-default status; the cards do not.** A field you can set and never see is worse than no field. `planning` is the column default and badging a default is noise (S4-1's quiet-panel argument). `archived` keeps `.badge.status-archived` exactly as today. The index and Home cards get the **New** badge and nothing else — the spec's "the projects index sorts/marks nothing else" is honoured.

7. **"Not a project" and Archive are ONE write and two sentences, deliberately.** Archiving *is* the dismissal mechanism (`docs/invariants/project-intake.md`, "THE CLAIM LOOKUP IS UNSCOPED"), and a second route performing the same write is the drift this codebase refuses. `#destroy` takes a `dismiss=1` param that changes the **flash and nothing else**; the write is `archive!` on both paths by construction. "Not a project" renders only when `discovered_at` is present — a hand-made project was never adopted, so the phrase means nothing there.

8. **A current-project switch that resolves to nothing is an ALERT and changes nothing.** Today `CurrentProjectController#update`'s `elsif` simply falls through (`current_project_controller.rb:11-14`). Keep that — do not clear. The message names neither ownership nor existence ("That project isn't available…"), because "that project is not yours" discloses that the id exists.

Everything else stands as written below. When a step conflicts with an amendment, the amendment wins.

---

## Decisions on the open questions (orchestrator review, 2026-09-07) — these override the text below

1. **No unique index in this slice.** The close-out files it as open work (`bin/log open`), whose
   first step is a read-only probe of the three live databases for an existing duplicate; a
   migration that can raise on live data is not written blind.
2. **A tombstoned folder is never silently re-minted, for ANY project.** `Project#ensure_library_folder!`
   mints `Projects/<slug>` only when `folder_node_id` is NIL (a form-created project that never had
   one); when the stored folder is a tombstone it returns nil and mints nothing. Every caller already
   tolerates nil (uploads fall back, the listing answers `available? == false`). The Files panel then
   says "This project's folder is in the trash or was removed. Restore it, or make another folder a
   project." with a link to Trash — for adopted and discovered projects alike, since deleting a folder
   in Finder is the maker's act and re-creating an empty one behind their back was the surprise
   (story 1.6's evidence). Pin with a test per door: the page, an upload, an attach-and-move.
3. **A folder an IMPORT-origin model claims stays adoptable**, and its model row is left alone.
4. **`discovery_sentence` fires on `:capped` too**: "created 50 of 63 folders under Projects/; the
   rest on the next scan." `RunResult` already carries `candidates` and `cap`.

- **The migration task also runs `bin/rails schema:map` and commits `docs/schema-map.html`** —
  `test/schema_map_test.rb` fails the full gate otherwise, and no per-task run reaches it (S4-2's gate).

When a step below conflicts with a decision here, the decision wins.

## Before you start

- Branch from `main` at `cb66cb7` (S4-1 through S4-5 all merged; nothing else is in flight in this worktree). Never push to `main`. **Amendment 1 is satisfied**: `maker_projects.autofile` exists (S4-2, PR #335). Since this plan was written, S4-4 moved the public project page's body into `app/views/public/projects/_page.html.erb` and S4-5 made the file page's viewers shared partials under `app/views/files/viewers/` — neither is this slice's territory, but any line number quoted below was measured before S4-2…S4-5 landed and has drifted; anchor every edit on the quoted TEXT. Subagents in this stage run on Opus.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; from a worktree `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`. The three legs (`test`, `test-s3`, `test-chunk-remote`) must report identical run counts.
- **Read first, in full:** `docs/invariants/project-intake.md` (every discovery bullet — this slice adds a SECOND door beside the sweep and must not weaken one of them), `docs/invariants/model-intake.md` ("A FOLDER A PROJECT CLAIMS IS THE PROJECT'S", the dismissal rules, `dismissed_at`/`auto_node_id`), `docs/invariants/design-system.md` rules 3 and 8, and CLAUDE.md §14d (form `scope:`, the ERB-comment rule, Stimulus) and §14a's `port_writable` bullet.
- **Two filenames in the spec and the overview are wrong.** There is no `test/integration/web/projects_test.rb` — it is **`projects_flow_test.rb`**. There is no `test/integration/web/current_project_test.rb` — the controller suite is **`test/controllers/current_project_controller_test.rb`**, with `current_project_topbar_test.rb` and `current_project_set_from_project_test.rb` beside it. There is no `files_test.rb` — the folder view lives in **`folder_nav_test.rb`** and the overflow menu in **`files_toolbar_test.rb`**.
- **Two files are contended with S4-2's Task E**: `app/views/projects/_form.html.erb` and `app/controllers/projects_controller.rb`. Take S4-2's **committed** state as your base and re-anchor on the surrounding markup, never on line numbers.
- Fixtures are port-free. A project folder in a request test is `project_folder_rows!(user, project)` (`test/test_helper.rb:163-179`) — never `ensure_library_folder!` (a real mkdir; red on s3 and chunk_remote). **An adoption test needs only rows**: the folder node it adopts is `@user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id:, size: 0, mtime: 1)`, and the door never calls the port.
- There is **no shared `sign_in`** and **no shared `#replacing`**. Each suite defines its own; copy the body verbatim from the file you are editing (`project_scan_button_test.rb:50-58` for `replacing`, `projects_flow_test.rb:23-28` for `sign_in`). The `own` ternary in `replacing` is load-bearing for `ActiveJob::Base#perform_now`.
- `git add` a new file before a mutation check; restore with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after an equal-length restore; `git status --porcelain` before the next run.
- Facts you will rely on, each verified by reading:
  - `Project#ensure_library_folder!` returns the existing node **without a mkdir** when `folder_node_id` names a live `kind: "dir"` row (`project.rb:145-148`). Its five callers — `ProjectsController#show:136`, `#ensure_project_folder:385`, `Projects::UploadsController#upload_parent:90`, `CurrentProject#current_project_folder_node_id:33`, `Maker::AttachToProject#move:357` — are therefore all no-ops for an adopted project. **No guard is needed; a test pins it.**
  - `Library::WorkingTree#root_for(node)` starts the walk at `node.parent_node_id` (`working_tree.rb:38-44`), so it answers **"is this node strictly INSIDE a working tree"** and returns `nil` for a folder that IS a repository root. That is exactly the refusal wanted, and it costs 2 queries per level, capped at `MAX_ANCESTOR_WALK` (64).
  - `Maker::LibraryTree#ancestors_of(node_id)` yields **nearest-first including the node itself**, ending with `nil`, and answers `nil` on a broken chain (`library_tree.rb:74-83`). `LibraryTree.new(user)` is one pluck of the user's dirs.
  - `Maker::ModelIntake.for_user` drops a project-claimed key **before `existing` is looked up**, so an auto model over an adopted folder stops accreting immediately — but its **row survives**, and clearing it is `Prune`'s job, not the sweep's (`model_intake.rb:87-95`, comment verbatim). For a folder model `auto_node_id == folder_node_id == the dir's node_id` (`model_intake.rb:112-116`), and `(user_id, auto_node_id)` carries a partial unique index (`db/schema.rb`).
  - `Maker::ProjectDiscoveryJob#perform` **returns its `RunResult`** (`project_discovery_job.rb`, last line of `#perform`), and `ActiveJob::Base.perform_now` returns what `#perform` returns.
  - `Maker::ProjectIntake::Result` is built at 3 sites in `project_intake.rb` and 3 in `project_scan_button_test.rb:118,134,151`. **This plan does not touch it** — S4-2's Task E does.
  - `Library::Observation` (`observation.rb:53`) is this repo's precedent for a `Data.define` member with a default: `def initialize(rel_path:, size:, mtime:, dir:, content_hash: nil) = super`. Spell every member; do not use anonymous `**`.
  - `page_query_budget_test.rb`'s `assert_constant_queries` does a **warm-up `get path` before each measurement** (`:59-77`), so `#show`'s once-only `opened_at` stamp is absorbed by the warm-up and never appears in either counted render.
  - `template_hygiene_test.rb`'s coverage assertion is **per TEMPLATE, not per branch** (`:449-457`). Every template this slice edits — `files/index.html.erb`, `projects/show.html.erb`, `projects/_card.html.erb`, `projects/_form.html.erb` — is already swept by its `pages` map, and this slice creates **no new partial**. That file therefore needs **no edit**; its two guards (leaked comment prose, leaked ERB delimiters) still cover every comment you add.

## File structure

| path | responsibility | task |
|---|---|---|
| new `db/migrate/20260907140000_add_discovery_marks_to_maker_projects.rb`, `db/schema.rb`, `docs/schema-map.html`, `app/models/maker/project.rb` (two comments); `test/schema_map_test.rb`, `test/models/tenant_cleanup_test.rb`, `test/models/structural_orphan_test.rb` (verify, expect no edit) | the two columns | **A** |
| `app/services/maker/project_discovery.rb` (`discovered_at`, `RunResult#names`, `.adoptable_name?`), `app/controllers/projects/scans_controller.rb` (`#pull_and_file`, `#scan_notice`); `test/services/maker/project_discovery_test.rb`, `test/integration/web/project_scan_button_test.rb` | discovery stamps, names and reports | **B** |
| new `app/controllers/projects/adoptions_controller.rb`, `config/routes.rb`, `app/controllers/files_controller.rb#index`, `app/views/files/index.html.erb`; new `test/integration/web/project_adoptions_test.rb`, `test/integration/web/files_toolbar_test.rb`, `test/integration/web/page_query_budget_test.rb` | the adoption door and its one control | **C** |
| `app/controllers/projects_controller.rb` (`#create`, `#show`, `#destroy`, `project_params`, `#ensure_project_folder`), `app/controllers/concerns/current_project.rb` (`#current_project_notice`), `app/controllers/current_project_controller.rb`, `app/views/projects/_form.html.erb`, `_card.html.erb`, `show.html.erb`, `app/assets/stylesheets/components.css`; `test/integration/web/projects_flow_test.rb`, `test/controllers/current_project_controller_test.rb`, `test/integration/web/home_test.rb`, `test/css_hygiene_test.rb` | the form, the flashes, the badge, Not-a-project | **D** |
| `test/system/shell_test.rb` (the phone sweep visits a folder view), `docs/invariants/project-intake.md`, `docs/invariants/model-intake.md`, `docs/user-stories.md`, `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` | the sweep, the documents, close-out | **E** |

**Dependencies and batches.**

1. **A alone.** B, C and D all read at least one of the two columns.
2. **B, C and D in parallel** — disjoint file sets, disjoint test files. (C and D both touch `projects_flow_test.rb`? They do **not**: every adoption test lives in the new `project_adoptions_test.rb`.)
3. **E** last: its documentation sweep names sentences the three implementing tasks falsify, and its phone-sweep path needs C's menu item to exist.

**Why one documentation task.** Four files under `docs/` describe behaviour this slice changes, and three of the implementing tasks each falsify a sentence in `docs/invariants/project-intake.md` alone. Parallel agents editing one Markdown file in one worktree is a recorded hazard (memory: `parallel-agents-one-worktree-rules`), and serialising three tasks to protect it would cost the batch. Task E is in the **same plan and the same PR**, and each implementing task's last step names, verbatim, the sentence it falsified. Do not let E slip out of this PR.

---

### Task A: the two columns

**Files:**
- Create: `db/migrate/20260907140000_add_discovery_marks_to_maker_projects.rb`
- Modify: `db/schema.rb` (generated), `docs/schema-map.html` (generated), `app/models/maker/project.rb`
- Test: `test/schema_map_test.rb`, `test/models/tenant_cleanup_test.rb`, `test/models/structural_orphan_test.rb`

- [ ] **Step 1: the migration.** `20260907140000` sits after S4-2's `20260907120000`/`20260907120100`, so both run forward on a database that already has either.

```ruby
class AddDiscoveryMarksToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    # WHO MADE THIS PROJECT, AND HAS ITS OWNER LOOKED AT IT YET (stage 4, S4-6; stories 1.1, 4.4).
    #
    # `discovered_at` is stamped by Maker::ProjectDiscovery and by nothing else — not by the web
    # form, not by Projects::AdoptionsController, not by the v1 API — so `discovered_at.present?`
    # IS the definition of "the app made this, I did not". It is a TIMESTAMP rather than a boolean
    # because the sweep already knows when it ran and the value costs the same either way; §12's
    # own history says a boolean that turns out to want a moment is a second migration.
    #
    # `opened_at` is stamped once, by ProjectsController#show, the first time the owner opens the
    # page. Together they are the "New" badge: discovered and not yet looked at. It is also the
    # first half of story 4.4's per-project "new since", which is why it is a moment and not a
    # `seen` flag.
    #
    # NEITHER COLUMN IS INDEXED, DELIBERATELY. Neither is ever a WHERE predicate: the badge is
    # evaluated in Ruby over rows the index and Home have ALREADY loaded, and #show reads the row
    # it just found by slug. An index here would be a btree write on every project save buying no
    # seek — and `architecture_invariants_test.rb:1135` would then want an argument for why
    # `(user_id, discovered_at)` is not a redundant prefix of something. No index, no argument.
    #
    # NULLABLE, NO DEFAULT: every existing project reads "I made this, and it is not new", which
    # is what a migration alone must mean (spec §4).
    add_column :maker_projects, :discovered_at, :datetime
    add_column :maker_projects, :opened_at,     :datetime
  end
end
```

- [ ] **Step 2: run it in both databases.** `bin/rails db:migrate && RAILS_ENV=test bin/rails db:prepare`. Confirm `db/schema.rb`'s `maker_projects` block now carries both columns, in the alphabetical position the dumper puts them (`discovered_at` after `description`, `opened_at` after `name`).

- [ ] **Step 3: regenerate the schema map.** `bin/rails schema:map`, then `bin/rails test test/schema_map_test.rb` → PASS. **This is not optional and it is the step most easily missed**: `docs/schema-map.html` embeds the parsed schema verbatim, so adding any column makes the checked-in page stale and `schema_map_test.rb:24` fails with "`docs/schema-map.html` is stale (its data moved)". No `SchemaMap::LAYOUT` or `EDGES` edit is needed — `maker_projects` is already in LAYOUT (`lib/schema_map.rb:79-81`) and neither new column points at another table's `id`, so there is no edge to draw and no `structural_orphan_test.rb` case to add.

- [ ] **Step 4: the model comments.** In `app/models/maker/project.rb`, beside `STATUSES` (`:7`):

```ruby
    # `discovered_at` / `opened_at` (stage 4, S4-6): see the migration for the full argument.
    # WRITTEN BY EXACTLY TWO PLACES AND NOWHERE ELSE — Maker::ProjectDiscovery stamps the first as
    # it creates a row, ProjectsController#show stamps the second once. Projects::AdoptionsController
    # leaves discovered_at nil ON PURPOSE and says so at its own create!: an adopted project is one
    # the maker made, so it is never "new to you" and never wears the badge.
```

- [ ] **Step 5: the two derived guards that need nothing, checked rather than assumed.** `bin/rails test test/models/tenant_cleanup_test.rb test/models/structural_orphan_test.rb` → PASS with **no edit**. `tenant_cleanup_test.rb` derives its table set from columns named `user_id` and already has a `maker_projects` builder; `structural_orphan_test.rb` derives from `SchemaMap::EDGES` and neither column adds one. Report the run rather than reasoning about it — memory `new-table-guard-checklist` records that the fourth guard is the one everybody misses, and "it needed nothing" is only true once you have run it.

- [ ] **Step 6: mutation check.** Delete the `add_column :maker_projects, :opened_at` line, re-run `bin/rails db:migrate:redo` … — **do not**. A migration is not the guard here; `schema_map_test.rb` is. Instead: revert `docs/schema-map.html` (`git checkout -- docs/schema-map.html` **before** committing it) and run `bin/rails test test/schema_map_test.rb` → FAILS with "`docs/schema-map.html` is stale (its data moved) — run `bin/rails schema:map`". Regenerate; PASS. Report both outputs.

- [ ] **Step 7: commit.**

```bash
git add db/migrate/20260907140000_add_discovery_marks_to_maker_projects.rb db/schema.rb docs/schema-map.html app/models/maker/project.rb
git commit -m "A project records when the app discovered it and when its owner first opened it"
```

---

### Task B: discovery stamps, names what it created, and the scan door reports it

**Files:**
- Modify: `app/services/maker/project_discovery.rb`, `app/controllers/projects/scans_controller.rb`
- Test: `test/services/maker/project_discovery_test.rb`, `test/integration/web/project_scan_button_test.rb`

**Depends on Task A** (`discovered_at`).

- [ ] **Step 1: the failing discovery tests.** Append inside `Maker::ProjectDiscoveryTest`'s class (its `setup` already builds `@user` and `@root`; its `dir`/`file` helpers are at `:11-17`). Every negative case here carries a positive control, which is this file's own house rule (`:96-110`):

```ruby
    # STORY 1.1 — "zero feedback: no flash, no 'new' marker". The marker is a column, and it is
    # written by THIS sweep and by nothing else, which is what lets a page read `discovered_at`
    # as "the app made this, I did not".
    test "a discovered project is stamped, and the whole run shares one moment" do
      dir("d-lamp", "Desk Lamp", @root.node_id)
      dir("d-tray", "Tray", @root.node_id)

      Maker::ProjectDiscovery.for_user(user: @user)

      stamps = @user.maker_projects.order(:name).pluck(:discovered_at)
      assert_equal 2, stamps.compact.size, "every row this sweep created carries the mark"
      assert_equal 1, stamps.uniq.size, "one run is one moment, not one moment per row"
    end

    # A hand-made project must NOT wear the badge, or the badge means nothing. Asserted here
    # rather than only in the web suite because the column's meaning is this class's to keep.
    test "a project created any other way is not stamped" do
      assert_nil @user.maker_projects.create!(name: "By Hand", slug: "by-hand").discovered_at
    end

    # THE RUN NAMES WHAT IT MADE, so a door with a user in front of it can say more than a count.
    # `names` follows the same DETERMINISTIC order `candidates` does (ORDER BY node_id), which is
    # what makes a capped run reproducible — see #adoptable.
    test "the run reports the names it created, in the order it created them" do
      dir("d-b", "Beta", @root.node_id)
      dir("d-a", "Alpha", @root.node_id)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal %w[Alpha Beta], run.names
      assert_equal 2, run.created
    end

    test "a run that creates nothing names nothing, and a run with nowhere to look does too" do
      assert_equal [], Maker::ProjectDiscovery.for_user(user: @user).names
      @root.update!(deleted: true)
      run = Maker::ProjectDiscovery.for_user(user: @user)
      assert_equal :no_projects_folder, run.status
      assert_equal [], run.names, "a Result built without names reads as none, never nil"
    end

    # ONE NAME RULE, TWO DOORS. Projects::AdoptionsController must refuse the names this sweep
    # refuses, or the two doors disagree about what a project folder may be called — and a `.git`
    # folder adopted by hand is a project literally titled ".git", the exact case #adoptable's own
    # dot rule exists to stop.
    test "the name rule is public, and it is the one the sweep itself applies" do
      assert Maker::ProjectDiscovery.adoptable_name?("Desk Lamp")
      refute Maker::ProjectDiscovery.adoptable_name?(".git")
      refute Maker::ProjectDiscovery.adoptable_name?(".hidden")
      refute Maker::ProjectDiscovery.adoptable_name?(nil)
    end
```

- [ ] **Step 2: run, expect four failures.** `bin/rails test test/services/maker/project_discovery_test.rb` → FAIL: `NoMethodError: undefined method 'names' for an instance of Maker::ProjectDiscovery::RunResult` and `undefined method 'adoptable_name?' for class Maker::ProjectDiscovery`, plus `Expected 2, got 0` on the stamp test.

- [ ] **Step 3: implement.** In `project_discovery.rb`, extend `RunResult` (currently `:26`):

```ruby
    RunResult = Data.define(:created, :candidates, :status, :cap, :names) do
      # `names` IS WHAT THIS RUN CREATED, in creation order — for a door that has a user in front
      # of it (stage 4, S4-6; story 1.1). `created` is a number and a number cannot answer "which
      # folders?", which is the only question a maker watching a scan actually has.
      #
      # A DEFAULT, so the :no_projects_folder construction above and any Result a test builds by
      # hand read as "created nothing" rather than raising. Library::Observation (observation.rb:53)
      # is this repo's precedent for the spelling; every member is named, because an anonymous
      # `**` forwarded through zsuper is a subtlety nobody should have to check.
      def initialize(created:, candidates:, status:, cap:, names: []) = super
    end
```

In `.for_user`, replace the `created = 0` / loop / final `RunResult` with:

```ruby
      created = []
      # ONE MOMENT FOR THE WHOLE RUN. These folders were discovered together, and a per-row
      # Time.current would make that legible nowhere while costing the same.
      now = Time.current
      candidates.first(cap).each do |node_id, name|
        user.maker_projects.create!(
          name:,
          slug: Maker::Project.available_slug(user, from: name),
          folder_node_id: node_id,
          # THE MARK THIS SWEEP OWNS (stage 4, S4-6). Nothing else writes it, so a page reading
          # `discovered_at.present?` is reading "the app made this" and not a proxy for it.
          discovered_at: now
        )
        created << name
      end

      RunResult.new(created: created.size, candidates: candidates.size,
                    status: capped ? :capped : :ok, cap:, names: created)
```

(Keep every existing comment inside the `create!` — the `available_slug` note and the "THE FOLDER ALREADY EXISTS" note both still apply.)

Beside `.adoptable`, add the shared predicate and make `adoptable` call it:

```ruby
    # MAY A FOLDER WITH THIS NAME BECOME A PROJECT? PUBLIC because Projects::AdoptionsController is
    # its second caller (stage 4, S4-6) and a door that spells the rule itself is a second copy —
    # the shape §14d names a service to end. #adoptable calls it too, so there is one definition
    # and the two doors cannot drift.
    #
    # THE DOT RULE IS THE WHOLE RULE, and its reason is `.git`: Library::OsClutter stops .DS_Store
    # and friends from ever becoming nodes, but `.git` IS THE ONE SKIP THAT KEEPS ITS ENTRY (§14b),
    # so without this a repository checked out at the Projects/ root — or picked in the folder view
    # — becomes a project literally titled ".git".
    def self.adoptable_name?(name) = !name.to_s.start_with?(".")
```

and in `adoptable`'s reject clause: `.reject { |node_id, name| claimed.include?(node_id) || !adoptable_name?(name) }`.

- [ ] **Step 4: run, expect PASS.** `bin/rails test test/services/maker/project_discovery_test.rb test/jobs/maker/project_discovery_job_test.rb test/jobs/library/scan_job_test.rb` → PASS. `scan_job_test.rb`'s `DiscoveryOrderTest` is the ordering guard and must stay green.

- [ ] **Step 5: the failing scan-door test.** In `project_scan_button_test.rb`, **replace** the body of "on chunk_remote the pull runs first and the intake second" so the order assertion covers all three steps, and add one flash test beside it:

```ruby
    # ORDER IS THE ASSERTION, and it is now THREE steps. The pull first, because a folder another
    # device pushed exists only after it. DISCOVERY SECOND, because Library::ScanJob sequences
    # discover -> file for a reason that changes the ANSWER and not the timing: a newly discovered
    # project's loose files have no shelf nearer than `Projects` itself, so filing before adopting
    # leaves them for the model catalog to swallow whole (docs/invariants/project-intake.md).
    test "on chunk_remote the pull runs first, discovery second and the intake third" do
      FileLayer.current = FileLayer::ChunkRemote.new
      order = []
      pull = ->(**) { order << :pull }
      discover = lambda do |**|
        order << :discover
        Maker::ProjectDiscovery::RunResult.new(created: 1, candidates: 1, status: :ok, cap: 50,
                                               names: [ "Tray" ])
      end
      file = lambda do |**|
        order << :file
        Maker::ProjectIntake::Result.new(attached: 2, moved: 1, skipped: 0,
                                         skips: [], plan: [], status: :ok)
      end
      replacing(FileLayer::RemoteChangelogPullJob, :perform_now, pull) do
        replacing(Maker::ProjectDiscoveryJob, :perform_now, discover) do
          replacing(Maker::ProjectIntake, :for_project, file) do
            post project_scan_path(@project)
          end
        end
      end
      assert_equal %i[pull discover file], order
      assert_redirected_to project_path(@project)
      assert_match(/attached 2/i, flash[:notice].to_s)
      assert_match(/filed 1/i, flash[:notice].to_s)
      # STORY 1.1: the door says WHICH folders became projects, not merely how many.
      assert_match(/Found 1 new project: Tray\./, flash[:notice].to_s)
    end

    # A STEADY-STATE SCAN SAYS NOTHING ABOUT DISCOVERY. Discovery's dominant outcome is "already
    # claimed", and a sentence printed on every click meaning nothing happened is the noise
    # Maker::ProjectDiscovery::RunResult's own header refuses for its skips breakdown.
    test "on chunk_remote a scan that discovers nothing says nothing about discovery" do
      FileLayer.current = FileLayer::ChunkRemote.new
      none = Maker::ProjectDiscovery::RunResult.new(created: 0, candidates: 0, status: :ok, cap: 50)
      quiet = Maker::ProjectIntake::Result.new(attached: 0, moved: 0, skipped: 0, skips: [],
                                               plan: [], status: :ok)
      replacing(FileLayer::RemoteChangelogPullJob, :perform_now, ->(**) { }) do
        replacing(Maker::ProjectDiscoveryJob, :perform_now, ->(**) { none }) do
          replacing(Maker::ProjectIntake, :for_project, ->(**) { quiet }) do
            post project_scan_path(@project)
          end
        end
      end
      refute_match(/new project/i, flash[:notice].to_s)
    end

    # SHARE/S3 ENQUEUES AND STOPS (§14f's race), so there is nothing in-request to report — and
    # this asserts that the door did not grow a synchronous discovery call to get a sentence.
    test "a scannable backend does NOT run discovery in the request either" do
      use_share!
      called = false
      replacing(Maker::ProjectDiscoveryJob, :perform_now, ->(**) { called = true }) do
        post project_scan_path(@project)
      end
      assert_not called, "the scan door must not sweep on a scannable backend — the badge is the surface there"
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end
```

- [ ] **Step 6: run, expect FAIL.** `bin/rails test test/integration/web/project_scan_button_test.rb` → the first test FAILS on `Expected: [:pull, :discover, :file] Actual: [:pull, :file]`.

- [ ] **Step 7: the scan door.** In `app/controllers/projects/scans_controller.rb`, `#pull_and_file` becomes:

```ruby
    def pull_and_file
      FileLayer::RemoteChangelogPullJob.perform_now(user_id: current_user.id)
      # DISCOVERY BETWEEN THE PULL AND THE FILE (stage 4, S4-6; story 1.1). The pull is what makes
      # a folder another device pushed visible at all; discovery must run BEFORE the intake for the
      # reason Library::ScanJob#discover_projects gives at length — a newly adopted project's loose
      # files have no shelf nearer than `Projects` itself, so the wrong order hands the whole folder
      # to the model catalog, permanently.
      #
      # THE JOB, NOT Maker::ProjectDiscovery — the idiom Library::ScanJob:233 already uses, and for
      # the same two reasons: the job is the only place a run is LOGGED, and #chain_intake is what
      # sweeps a project this call has just created (`.for_project` below sweeps THIS project only).
      # `perform_now` creates no job row, so ProjectDiscoveryJob's `limits_concurrency` does not
      # engage here — the same gap that job's own header records for Library::ScanJob's call. What
      # bounds it here is this controller's `rate_limit to: 3, within: 1.minute, by: user`. A
      # partial unique index on (user_id, folder_node_id) is the durable fix and is open work.
      run = Maker::ProjectDiscoveryJob.perform_now(user_id: current_user.id)
      result = Maker::ProjectIntake.for_project(user: current_user, project: @project)
      redirect_to project_path(@project), notice: scan_notice(result, run)
    end
```

`#scan_notice` takes the run and appends one sentence:

```ruby
    # How many created folders the flash will NAME before it starts counting. MAX_PROJECTS is 50,
    # and a flash listing fifty folder names is not a sentence.
    SCAN_NAMES_SHOWN = 3

    def scan_notice(result, run)
      return "Scanned your library. #{@project.name} has no folder yet, so nothing was filed." if
        result.status == :no_folder

      lead = if result.attached.zero? && result.moved.zero?
        "Scanned your library — nothing new for #{@project.name}"
      else
        "Scanned your library — attached #{result.attached}, filed #{result.moved}"
      end
      [ project_intake_sentence(lead, result, unfiled_by_conflict(result, result.skips.map(&:first))),
        discovery_sentence(run) ].compact.join(" ")
    end

    # WHAT DISCOVERY CREATED, BY NAME (stage 4, S4-6; story 1.1). Discovery reported to the log and
    # nowhere else — a folder became a project and the only witness was a log line the maker never
    # reads. NIL WHEN IT CREATED NOTHING, because "already claimed" is the steady state and a
    # sentence on every click meaning nothing happened is noise, which is the argument
    # Maker::ProjectDiscovery::RunResult's own header makes for having no skips breakdown at all.
    def discovery_sentence(run)
      return nil unless run.respond_to?(:created) && run.created.positive?

      shown = run.names.first(SCAN_NAMES_SHOWN)
      rest  = run.names.size - shown.size
      tail  = rest.positive? ? "#{shown.to_sentence} and #{rest} more" : shown.to_sentence
      "Found #{run.created} new #{'project'.pluralize(run.created)}: #{tail}."
    end
```

- [ ] **Step 8: run, expect PASS.** `bin/rails test test/integration/web/project_scan_button_test.rb test/system/project_scan_reload_test.rb`.

- [ ] **Step 9: mutation checks — three.**
  1. In `.for_user` drop `discovered_at: now` from the `create!`; run `project_discovery_test.rb` → FAILS on "a discovered project is stamped" (`Expected: 2 Actual: 0`). Restore.
  2. In `adoptable`'s reject clause put `name.to_s.start_with?(".")` back inline and change `adoptable_name?` to `def self.adoptable_name?(_name) = true`; run `project_discovery_test.rb` → the "dot-folders are skipped" test stays **GREEN** while "the name rule is public" goes RED — which is the point: the guard that catches a door drifting is the predicate's own test, not the sweep's. Report both, then restore.
  3. In `#pull_and_file` move the discovery line **after** the intake; run `project_scan_button_test.rb` → FAILS `Expected: [:pull, :discover, :file] Actual: [:pull, :file, :discover]`. Restore. Report all six outputs.

- [ ] **Step 10: commit.**

```bash
git add app/services/maker/project_discovery.rb app/controllers/projects/scans_controller.rb test/services/maker/project_discovery_test.rb test/integration/web/project_scan_button_test.rb
git commit -m "Discovery marks what it made and says which folders became projects"
```

- [ ] **Step 11: hand Task E its sentences.** `docs/invariants/project-intake.md` needs: `discovered_at` as the sweep's own mark; `.adoptable_name?` as the ONE name rule now shared with a second door; and the scan door's new discovery call with the `limits_concurrency` gap named.

---

### Task C: the adoption door, and the one control that opens it

**Files:**
- Create: `app/controllers/projects/adoptions_controller.rb`
- Modify: `config/routes.rb`, `app/controllers/files_controller.rb` (`#index`'s folder branch), `app/views/files/index.html.erb`
- Test: create `test/integration/web/project_adoptions_test.rb`; modify `test/integration/web/files_toolbar_test.rb`, `test/integration/web/page_query_budget_test.rb`

**Depends on Task A** (`discovered_at`) **and on S4-2 having landed** (`autofile` — amendment 1, 4).

- [ ] **Step 1: the route.** Inside the existing `resources :projects do … end` block (`config/routes.rb:139-181`), directly under the `patch :unarchive, on: :member` line:

```ruby
    # ADOPT IN PLACE (stage 4, S4-6; spec decision D1). A folder ANYWHERE in the library becomes a
    # project without moving: the row's folder_node_id simply points there. A COLLECTION route
    # because there is no project yet — the FOLDER is the subject, and it rides as params[:node_id].
    #
    # Under `projects/` so ShellHelper::SECTIONS lights the Projects rail item off
    # controller_path's first segment (design-system rule 8) with no map edit. It is a POST and
    # always redirects, so the rail is never actually rendered for it — stated so the next reader
    # does not go looking for a missing SECTIONS entry.
    post :adopt, on: :collection, to: "projects/adoptions#create"
```

- [ ] **Step 2: verify the helper name before writing a test against it.** `bin/rails routes -g adopt`. Expect `adopt_projects POST /projects/adopt projects/adoptions#create` → the helper is `adopt_projects_path`. **Report the actual output**; if it differs, use what it prints everywhere below rather than what this plan guessed.

- [ ] **Step 3: the failing door tests.** Create `test/integration/web/project_adoptions_test.rb`. Note there is **no port call anywhere** — every fixture is rows, which is what makes this file identical on all three legs:

```ruby
require "test_helper"

module Web
  # ADOPT IN PLACE (stage 4, S4-6; decision D1, stories 1.3 and 4.7). A folder anywhere in the
  # library becomes a project by one POST that moves nothing.
  #
  # PORT-FREE ON PURPOSE, and that is what makes it identical on all three CI legs: the door reads
  # `nodes`, writes one `maker_projects` row and at most one `dismissed_at`, and never touches
  # FileLayer — the same property docs/invariants/project-intake.md records for the discovery sweep.
  # Fixtures are therefore bare `nodes.create!` rows; ensure_library_folder! must never appear here.
  class ProjectAdoptionsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "adopt-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    def dir(node_id, name, parent = nil)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent = nil)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    # --- the happy path -------------------------------------------------------

    test "a folder outside Projects becomes a project that keeps its path" do
      designs = dir("d-designs", "designs")
      tray = dir("d-tray", "tray", designs.node_id)

      assert_difference "Maker::Project.count", 1 do
        post adopt_projects_path, params: { node_id: tray.node_id }
      end

      project = @user.maker_projects.order(:id).last
      assert_equal "tray", project.name
      assert_equal "tray", project.slug
      assert_equal "planning", project.status
      assert_equal tray.node_id, project.folder_node_id
      assert_redirected_to project_path(project)
      assert_match(/Made “tray” a project/, flash[:notice].to_s)
      assert_match(/files stay where they are/i, flash[:notice].to_s)
    end

    # THE FOLDER IS NOT MOVED, MINTED OR RENAMED — the whole of D1 in one assertion. `Projects/`
    # must not come into existence as a side effect of adopting something outside it, which is the
    # bug Projects::AttachmentsController#relocate shipped, one door over.
    test "adopting mints no node, moves nothing and never creates Projects/" do
      tray = dir("d-tray", "tray", dir("d-designs", "designs").node_id)
      before = @user.nodes.order(:node_id).pluck(:node_id, :name, :parent_node_id)

      post adopt_projects_path, params: { node_id: tray.node_id }

      assert_equal before, @user.nodes.order(:node_id).pluck(:node_id, :name, :parent_node_id)
      assert_nil @user.nodes.find_by(name: Maker::ProjectFolders::ROOT, parent_node_id: nil)
    end

    # AMENDMENT 4. "My NAS layout stays mine" (story 1.3) is the point of adopting in place, and a
    # sweep that re-files `tray.svg` into `design/` fifteen minutes later is the fight-the-user
    # failure §14f exists to prevent, arriving through a new door. Discovery keeps the `true`
    # default: a folder the maker put under Projects/ asked for the app's filing by being there.
    test "an adopted project has automatic filing off, and the flash says so" do
      tray = dir("d-tray", "tray")

      post adopt_projects_path, params: { node_id: tray.node_id }

      refute @user.maker_projects.order(:id).last.autofile?
      assert_match(/automatic filing is off/i, flash[:notice].to_s)
    end

    # An adopted project is one the MAKER made, so it must never wear the "New" badge.
    test "an adopted project is not marked as discovered" do
      post adopt_projects_path, params: { node_id: dir("d-tray", "tray").node_id }
      assert_nil @user.maker_projects.order(:id).last.discovered_at
    end

    # A folder DIRECTLY under Projects/ is adoptable through this door too — it is what discovery
    # would have done on its next tick, and doing it now is not a different act. The claim the row
    # takes is what makes the sweep pass over it afterwards (the row is the memory).
    test "a folder under Projects can be adopted by hand, and the sweep then passes over it" do
      root = dir("d-projects", Maker::ProjectFolders::ROOT)
      lamp = dir("d-lamp", "Desk Lamp", root.node_id)

      post adopt_projects_path, params: { node_id: lamp.node_id }
      assert_equal lamp.node_id, @user.maker_projects.order(:id).last.folder_node_id

      assert_no_difference "Maker::Project.count" do
        Maker::ProjectDiscovery.for_user(user: @user)
      end
    end

    # THE FOLDER IS A REPOSITORY ROOT — adopt it. §14f's :in_working_tree refusal already stops the
    # sweep moving a working tree's files, so this needs no special case; the assertion exists so
    # that a later refusal written for "inside a repository" cannot swallow the root as well.
    test "a folder that IS a git working tree can be adopted" do
      repo = dir("d-fw", "firmware")
      dir("d-fw-git", Library::RepoMetadata::DIR_NAME, repo.node_id)

      assert_difference "Maker::Project.count", 1 do
        post adopt_projects_path, params: { node_id: repo.node_id }
      end
    end

    # --- the refusals ---------------------------------------------------------

    test "no node_id refuses, and creates nothing" do
      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: "" }
      end
      assert_redirected_to files_path
      assert_match(/pick a folder/i, flash[:alert].to_s)
    end

    test "a file, a tombstone and another user's folder are all just 'not in your library'" do
      loose = file("n-loose", "shot.png")
      dead = dir("d-dead", "gone")
      dead.update!(deleted: true)
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: "d-theirs", name: "theirs", kind: "dir", mtime: 1, size: 0)

      [ loose.node_id, dead.node_id, theirs.node_id, "nope" ].each do |id|
        assert_no_difference "Maker::Project.count" do
          post adopt_projects_path, params: { node_id: id }
        end
        assert_match(/isn't in your library/i, flash[:alert].to_s, "for #{id}")
      end
    end

    test "a dot-folder is refused by the same rule the sweep applies" do
      git = dir("d-git", Library::RepoMetadata::DIR_NAME)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: git.node_id }
      end
      assert_match(/starts with a dot/i, flash[:alert].to_s)
    end

    test "the Projects root itself is refused" do
      root = dir("d-projects", Maker::ProjectFolders::ROOT)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: root.node_id }
      end
      assert_match(/where project folders live/i, flash[:alert].to_s)
    end

    # UNSCOPED ON STATUS — an ARCHIVED project still claims its folder, and that IS the dismissal
    # mechanism (docs/invariants/project-intake.md). Adopting a dismissed folder through this door
    # would be the "how a dismissed thing comes back" bug with a new door on it.
    test "a folder an existing project claims is refused, archived included, and names it" do
      tray = dir("d-tray", "tray")
      existing = @user.maker_projects.create!(name: "Tray", slug: "tray", folder_node_id: tray.node_id,
                                              status: "archived", archived_at: Time.current)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: tray.node_id }
      end
      assert_redirected_to project_path(existing)
      assert_match(/already the folder for Tray/, flash[:alert].to_s)
    end

    test "a folder inside another project's folder is refused and names that project" do
      lamp_dir = dir("d-lamp", "Desk Lamp")
      @user.maker_projects.create!(name: "Desk Lamp", slug: "desk-lamp", folder_node_id: lamp_dir.node_id)
      inner = dir("d-inner", "laser", lamp_dir.node_id)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: inner.node_id }
      end
      assert_match(/inside Desk Lamp/, flash[:alert].to_s)
    end

    # Adopting a repository's `src/` makes a project whose folder git owns but whose ROOT is
    # somewhere else — the README, the commits and the history all sit outside it, so S4-1's whole
    # repository card answers about the wrong tree. Point the maker at the root instead.
    test "a folder inside a working tree that is not its root is refused and names the root" do
      repo = dir("d-fw", "firmware")
      dir("d-fw-git", Library::RepoMetadata::DIR_NAME, repo.node_id)
      src = dir("d-src", "src", repo.node_id)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: src.node_id }
      end
      assert_match(/inside the git repository “firmware”/, flash[:alert].to_s)
    end

    # --- the model that was already there -------------------------------------

    # STORY 1.3's measured friction: the seeded `*` shelf makes every top-level folder a shelf, so
    # `designs/tray` had already become a MODEL. Maker::ModelIntake stops accreting the moment a
    # project claims the folder (model_intake.rb:87-95), but the ROW SURVIVES — its own comment says
    # clearing it is Prune's job — so without this the folder is a project AND a model, forever.
    test "an auto model over the adopted folder is dismissed, and the flash says so" do
      tray = dir("d-tray", "tray", dir("d-designs", "designs").node_id)
      model = @user.maker_models.create!(title: "tray", slug: "tray", origin: "auto",
                                         auto_node_id: tray.node_id, folder_node_id: tray.node_id)

      post adopt_projects_path, params: { node_id: tray.node_id }

      assert_not_nil model.reload.dismissed_at
      assert_match(/no longer listed as a model/i, flash[:notice].to_s)
      # DISMISSED, NOT DESTROYED: the row is the memory, and destroying it makes the next sweep
      # recreate it the moment the project is deleted (docs/invariants/model-intake.md).
      assert Maker::Model.exists?(model.id)
    end

    test "an import model over the adopted folder is left alone" do
      tray = dir("d-tray", "tray")
      model = @user.maker_models.create!(title: "Tray Kit", slug: "tray-kit", origin: "import",
                                         folder_node_id: tray.node_id)

      post adopt_projects_path, params: { node_id: tray.node_id }

      assert_nil model.reload.dismissed_at, "nothing recreates an import model, so there is nothing to dismiss"
      refute_match(/no longer listed as a model/i, flash[:notice].to_s)
    end

    # --- what the adopted project's own surfaces do ---------------------------

    # The five callers of ensure_library_folder! are all no-ops for a live folder (project.rb:145-148),
    # so nothing on the project page mints `Projects/<slug>` beside the folder the maker adopted.
    # Asserted through the real page, because "it is a no-op" is a claim about code and this is a
    # claim about the request (§15: drive the real request).
    test "opening an adopted project's page mints no second folder and lists its own path" do
      tray = dir("d-tray", "tray", dir("d-designs", "designs").node_id)
      file("n-svg", "tray.svg", tray.node_id)
      post adopt_projects_path, params: { node_id: tray.node_id }
      project = @user.maker_projects.order(:id).last

      get project_path(project)

      assert_response :success
      assert_equal tray.node_id, project.reload.folder_node_id
      assert_nil @user.nodes.find_by(name: Maker::ProjectFolders::ROOT, parent_node_id: nil)
      assert_select ".attachments-panel .panel-path", text: "designs/tray"
    end

    test "requires sign-in" do
      delete destroy_user_session_path
      post adopt_projects_path, params: { node_id: "d-x" }
      assert_redirected_to new_user_session_path
    end
  end
end
```

- [ ] **Step 4: run, expect a routing error.** `bin/rails test test/integration/web/project_adoptions_test.rb` → every test FAILS with `uninitialized constant Projects::AdoptionsController` (or a routing error if step 1 was skipped).

- [ ] **Step 5: the controller.** Create `app/controllers/projects/adoptions_controller.rb`:

```ruby
module Projects
  # ADOPT IN PLACE (stage 4, S4-6; spec decision D1, stories 1.3 and 4.7). A live directory node
  # anywhere in the library becomes a project: one `maker_projects` row whose folder_node_id points
  # at that node, and nothing else. No mkdir, no move, no rename, no second kind of thing.
  #
  # A DOOR, NOT A SWEEP — the distinction the spec settles and the reason this class can be small.
  # Maker::ProjectDiscovery keeps every rule it has (direct children of `Projects/`, the unscoped
  # claim lookup, never minting `Projects/`, the caps); this is a second entrance onto the SAME
  # concept, so it shares discovery's name rule (.adoptable_name?) rather than spelling one, and it
  # takes the same can't-fail slug (Maker::Project.available_slug) for the same reason a sweep does:
  # a folder named `模型` or one colliding with a hand-made project must not raise at the user.
  #
  # NOTHING DOWNSTREAM NEEDED A CHANGE, and that is the design working rather than an omission.
  # Maker::ProjectFolderListing resolves the folder through the LibraryTree from folder_node_id
  # alone; Maker::ProjectIntake#live_folder reads the same column and #place resolves its category
  # folders UNDER THAT NODE, never a path rebuilt from the slug (§14f); and
  # Project#ensure_library_folder! returns early whenever the column names a live dir, so none of
  # its five callers mints `Projects/<slug>` beside the folder the maker chose.
  #
  # THE REFUSALS ARE ORDERED CHEAPEST FIRST, and each answers with the ACTION that would work
  # instead of merely with the failure — the shape §14a requires of ChunkRemote's own 409.
  class AdoptionsController < ApplicationController
    def create
      node_id = params[:node_id].to_s.presence
      return refuse(nil, "Pick a folder first.") if node_id.nil?

      # A FILE, A TOMBSTONE, ANOTHER USER'S NODE AND A TYPO ARE ONE ANSWER, deliberately. Telling
      # them apart would disclose that an id exists, and none of the four is a different act for
      # the maker to take.
      node = current_user.nodes.present.find_by(node_id:, kind: "dir")
      return refuse(nil, "That folder isn't in your library.") unless node

      refusal = refusal_for(node)
      return refusal if refusal

      project = adopt!(node)
      redirect_to project_path(project), notice: adopted_notice(node, project, @dismissed_model)
    end

    private

    # Returns a redirect (already performed) or nil. Split out so #create reads as the four steps
    # it is; every branch here creates NOTHING, which is what makes a refusal recoverable.
    def refusal_for(node)
      unless Maker::ProjectDiscovery.adoptable_name?(node.name)
        return refuse(node, "A folder whose name starts with a dot can't be a project.")
      end

      # `Projects/` ITSELF. Adopting it would make one project holding every other project's folder
      # — and would then claim the root against discovery, which reads the same column, silently
      # switching the whole feature off.
      if node.parent_node_id.nil? && node.name == Maker::ProjectFolders::ROOT
        return refuse(node, "#{Maker::ProjectFolders::ROOT} is where project folders live — " \
                            "pick one of the folders inside it.")
      end

      claim = claim_on(node)
      return claim if claim

      # STRICTLY INSIDE A WORKING TREE. Library::WorkingTree#root_for starts its walk at the node's
      # PARENT, so a folder that IS a repository root answers nil here and is adoptable — which is
      # what story 1.4 wants. What this refuses is `firmware/src`: a project whose README, commits
      # and history all sit OUTSIDE its own folder, so S4-1's repository card answers about a tree
      # the project does not contain.
      root = Library::WorkingTree.new(current_user).root_for(node)
      if root
        return refuse(node, "“#{node.name}” is inside the git repository “#{root.name}”. " \
                            "Make the repository's own folder the project instead.")
      end

      nil
    end

    # ONE ANCESTOR WALK ANSWERS BOTH CLAIM QUESTIONS. Maker::LibraryTree#ancestors_of yields the
    # node ITSELF first and then climbs, so the head of the chain is "this folder is already a
    # project" and the tail is "this folder is inside one".
    #
    # UNSCOPED ON STATUS, exactly as Maker::ProjectDiscovery#adoptable and
    # Maker::ModelIntake.claimed_folders are: an ARCHIVED project keeps folder_node_id and still
    # claims its folder, and THE ROW IS THE MEMORY. Filtering archived rows out here is precisely
    # how a dismissed folder comes back — with a button on it.
    def claim_on(node)
      chain = Maker::LibraryTree.new(current_user).ancestors_of(node.node_id)
      # nil is an unresolvable/cyclic chain (library_tree.rb's :broken sentinel). Refuse rather
      # than adopt into a tree we cannot describe.
      return refuse(node, "That folder's place in the library can't be resolved right now.") if chain.nil?

      by_folder = current_user.maker_projects.where(folder_node_id: chain.compact)
                              .index_by(&:folder_node_id)
      return nil if by_folder.empty?

      if (own = by_folder[node.node_id])
        return redirect_to project_path(own),
                           alert: "“#{node.name}” is already the folder for #{own.name}."
      end

      ancestor = chain.compact.find { |id| by_folder.key?(id) }
      owner = by_folder[ancestor]
      refuse(node, "“#{node.name}” is inside #{owner.name}'s folder, so its files already " \
                   "belong to that project.")
    end

    def adopt!(node)
      project = nil
      ActiveRecord::Base.transaction do
        project = current_user.maker_projects.create!(
          # THE FOLDER IS THE TRUTH (stage 4, §7): the project is named for the folder, verbatim,
          # exactly as discovery names one. The slug may diverge from the name forever and that is
          # the mainline case, not an edge case (§14f).
          name: node.name,
          slug: Maker::Project.available_slug(current_user, from: node.name),
          status: "planning",
          folder_node_id: node.node_id,
          # NOT DISCOVERED. The maker made this, so it is never "new to you" and never wears the
          # badge — `discovered_at.present?` is the whole definition of auto-created (S4-6).
          discovered_at: nil,
          # AUTOMATIC FILING OFF (stage 4, S4-6; story 1.3). Adopting a folder in `designs/` says
          # what it IS; it does not ask for it to be rearranged. Left on, the sweep moves
          # `tray.svg` into `design/` and `notes.md` into `docs/` within fifteen minutes, unasked
          # — the fight-the-user failure §14f exists to prevent, through a new door. Discovery
          # keeps the `true` default: a folder placed under `Projects/` asked for filing by being
          # there. The edit form is where a maker turns it on (S4-2), and the flash points at it.
          autofile: false
        )
        @dismissed_model = dismiss_auto_model(node)
      end
      project
    end

    # THE MODEL THIS FOLDER HAD ALREADY BECOME (story 1.3). The seeded `*` shelf makes every
    # top-level folder a shelf, so `designs/tray` was catalogued as a Maker::Model before anyone
    # thought to call it a project. Maker::ModelIntake stops accreting the instant a project claims
    # the folder — its own comment says so — but the ROW SURVIVES, so the folder would be a project
    # AND a model at once, with the model's card offering Delete for a thing that is now a build.
    #
    # DISMISSED, NOT DESTROYED, and NOT a Prune run. `dismissed_at` is the documented "I do not want
    # this" (docs/invariants/model-intake.md), and it is the SAME write ModelsController#destroy
    # makes for an auto model. Destroying instead would let the sweep recreate the row the moment
    # the project is deleted and releases the folder — the row is the memory, in both directions.
    #
    # AUTO ONLY. Nothing recreates an IMPORT-origin model, so there is nothing for a dismissal to
    # say to the sweep; that folder is `Models/<slug>`, minted by an import, and leaving its row
    # alone is the same "look, do not take" reading the intake already applies to it.
    #
    # Keyed on `auto_node_id`, which for a FOLDER model equals the dir's own node_id and carries the
    # partial unique index on (user_id, auto_node_id) — one indexed lookup, not a scan.
    def dismiss_auto_model(node)
      model = current_user.maker_models.find_by(origin: "auto", auto_node_id: node.node_id)
      return nil unless model && model.dismissed_at.nil?

      model.update!(dismissed_at: Time.current)
      model
    end

    def adopted_notice(node, _project, model)
      sentences = [ "Made “#{node.name}” a project — its files stay where they are, and " \
                    "automatic filing is off, so nothing moves." ]
      sentences << "It is no longer listed as a model." if model
      sentences.join(" ")
    end

    # BACK TO THE FOLDER THE MAKER WAS LOOKING AT, so a refusal leaves them where they can act on
    # it. `node` nil (no id, or an id that resolved to nothing) falls back to the library root
    # rather than echoing an unresolved param into a URL.
    def refuse(node, message)
      redirect_to files_path(folder: node&.node_id), alert: message
    end
  end
end
```

- [ ] **Step 6: run, expect PASS.** `bin/rails test test/integration/web/project_adoptions_test.rb` → all green.

- [ ] **Step 7: the failing menu tests.** Append to `test/integration/web/files_toolbar_test.rb` (its `setup` at `:11-29` already builds `dir-cad` and four files, and signs `@user` in):

```ruby
    # STORY 1.3 / 4.7 — the one door onto adoption. It renders on the FOLDER view only: the flat
    # view and the root are questions about the library, and there is no folder there to adopt.
    test "a folder view offers 'Make this folder a project', and the root does not" do
      get files_path(folder: "dir-cad")
      assert_select ".page-actions details.menu form[action=?] button.menu-item",
                    adopt_projects_path, text: /make this folder a project/i
      assert_select ".page-actions details.menu form[action=?] input[name=?][value=?]",
                    adopt_projects_path, "node_id", "dir-cad"

      get files_path
      assert_select "form[action=?]", adopt_projects_path, count: 0
    end

    # THE MENU MUST NOT OFFER WHAT THE DOOR WOULD REFUSE for a reason the page can see for free.
    # The expensive refusals (an ancestor's claim, a working tree) stay in the controller; these
    # two are a string test and a nil test on a row the page already holds.
    test "the adopt item is absent for a dot-folder and for the Projects root" do
      projects = @user.nodes.create!(node_id: "dir-projects", name: Maker::ProjectFolders::ROOT,
                                     kind: "dir")
      dot = @user.nodes.create!(node_id: "dir-dot", name: ".hidden", kind: "dir")

      # `?hidden=` is not needed: it filters which CHILDREN are listed, and FilesController
      # #current_folder resolves params[:folder] by node_id regardless of the dot rule.
      [ projects, dot ].each do |folder|
        get files_path(folder: folder.node_id)
        # BRACES ON THE EQUALITY HASH. `assert_select sel, arg, count: 0, "msg"` is a Ruby SYNTAX
        # ERROR — a positional argument cannot follow a braceless hash — and rails-dom-testing's
        # signature is (selector, *substitutions, equality, message). Every other assertion in this
        # plan puts the hash last and needs no braces; this one carries a message.
        assert_select "form[action=?]", adopt_projects_path, { count: 0 }, "for #{folder.name}"
      end
    end

    # A CLAIMED FOLDER OFFERS THE PROJECT, NOT THE VERB. Unscoped on status, like every other
    # reader of this claim: an archived project still owns its folder, and the page saying nothing
    # about it is how a maker ends up with two projects for one folder.
    test "a folder a project already claims links to that project instead" do
      project = @user.maker_projects.create!(name: "Cad Build")
      project.update_column(:folder_node_id, "dir-cad")

      get files_path(folder: "dir-cad")

      assert_select ".page-actions details.menu a.menu-item[href=?]", project_path(project),
                    text: /Cad Build/
      assert_select "form[action=?]", adopt_projects_path, count: 0
    end

    # The menu itself must appear on a folder view even where it would otherwise be empty —
    # chunk_remote is not scannable and has no current project here, so before this slice the
    # `details.menu` did not render at all and the item would have had nowhere to go.
    test "the overflow menu renders on a folder view on every backend" do
      get files_path(folder: "dir-cad")
      assert_select ".page-actions details.menu[data-controller='menu'] summary.btn", count: 1
    end
```

- [ ] **Step 8: run, expect FAIL.** `bin/rails test test/integration/web/files_toolbar_test.rb` → the four new tests fail on the missing selector. **The five pre-existing menu assertions must stay green**: "rescan lives in the overflow menu", "no menu renders when it would be empty" and the current-project pair all GET **bare `files_path`**, where `@folder` is nil, so the new branch never fires for them. Confirm that in the run output rather than assuming it.

- [ ] **Step 9: the controller's one new read.** In `FilesController#index`, inside the `else` (folder) branch, directly after `@crumbs = folder_crumbs(@folder)`:

```ruby
      # WHO, IF ANYONE, ALREADY CLAIMS THIS FOLDER (stage 4, S4-6). ONE query, constant in N, and
      # only on the folder view — the flat view is a question about the library and has no folder
      # to adopt. It buys two things at once: the menu offers "Open project X" instead of a verb
      # that would 302 straight back with "already a project", and the same row names the project
      # in that refusal if a stale page posts anyway.
      #
      # UNSCOPED ON STATUS, like every other reader of this claim (Maker::ProjectDiscovery#adoptable,
      # Maker::ModelIntake.claimed_folders): an ARCHIVED project still owns its folder, and a page
      # that pretended otherwise would offer to make a second project for it.
      #
      # THE COST IS NAMED RATHER THAN WAVED AT: this is the app's busiest page (§12.8 tracks its
      # render cost), and `folder_node_id` carries no index — but the scan is over the user's own
      # projects, of which the measured real library has nine. page_query_budget_test.rb's folder
      # view asserts constancy in N and now actually visits a folder, so a per-row version of this
      # could not hide.
      @folder_project = @folder && current_user.maker_projects.find_by(folder_node_id: @folder.node_id)
```

(In the flat branch, set `@folder_project = nil` beside `@folder = nil` / `@crumbs = []`, so the view never reads an undefined ivar.)

- [ ] **Step 10: the view.** In `app/views/files/index.html.erb`, extend the menu gate (`:38`) and add the item inside `.menu-list`, after the Rescan block and before the current-project block:

```erb
<% adoptable_folder = @folder && @folder_project.nil? &&
                      Maker::ProjectDiscovery.adoptable_name?(@folder.name) &&
                      !(@folder.parent_node_id.nil? && @folder.name == Maker::ProjectFolders::ROOT) %>
<% menu_items = capabilities.scannable? || current_project.present? || @folder.present? %>
```

```erb
          <% if @folder_project %>
            <%= link_to "Open project “#{@folder_project.name}”", project_path(@folder_project),
                        class: "menu-item" %>
          <% elsif adoptable_folder %>
            <%#
              ADOPT IN PLACE (stage 4, S4-6; decision D1, stories 1.3 and 4.7). One POST turns the
              folder being viewed into a project that keeps its path — the answer to "a fifth of my
              files live outside Projects/" that does not ask the maker to move anything.

              THE TWO CHEAP REFUSALS ARE ASKED HERE TOO, and only those two: a dot-folder and the
              Projects root are a string test and a nil test on the row this page already holds.
              The expensive ones — an ancestor's claim, a working tree — stay in the controller,
              which is the only place that may be the authority; this just declines to offer a
              button whose answer the page already knows.
            %>
            <%= button_to "Make this folder a project", adopt_projects_path,
                          params: { node_id: @folder.node_id }, class: "menu-item" %>
          <% end %>
```

**No `%>` inside an ERB comment** (§14d's recorded leak: an ERB comment ends at its FIRST `%>`, and `template_hygiene_test.rb` catches the result only on the rendered page).

- [ ] **Step 11: run, expect PASS.** `bin/rails test test/integration/web/files_toolbar_test.rb test/integration/web/folder_nav_test.rb test/integration/web/files_flow_test.rb test/integration/web/files_git_marker_test.rb test/integration/web/files_search_test.rb test/integration/web/files_type_filter_test.rb test/integration/web/files_sort_test.rb test/integration/web/template_hygiene_test.rb test/system/files_pages_test.rb`.

- [ ] **Step 12: the folder budget starts measuring a folder.** `page_query_budget_test.rb:508`'s test is named "files#index folder view" and GETs **bare `files_path`** — the library root, where `@folder` is nil and the branch this task adds never runs. Correct it so the name and the measurement agree, and so the new query is actually budgeted:

```ruby
    # A REAL FOLDER, NOT THE ROOT. This test has always been named for the folder view and has
    # always measured the root, where `@folder` is nil — so the folder branch's own reads (the
    # breadcrumb walk, and since S4-6 the project-claim lookup) were never under measurement at
    # all. The root's flat branch is still covered by "files#index does not grow with the number of
    # addon-produced files" below.
    test "files#index folder view does not grow with the number of nodes" do
      folder = @user.nodes.create!(node_id: "budget-dir", name: "cad", kind: "dir",
                                   mtime: 1, size: 0)
      add = lambda do |prefix, count|
        count.times do |i|
          node!("#{prefix}#{i}", "#{prefix}#{i}.stl")
          @user.nodes.find_by!(node_id: "#{prefix}#{i}").update!(parent_node_id: folder.node_id)
        end
      end
      assert_constant_queries(files_path(folder: folder.node_id),
                              -> { add.call("fs", SMALL) },
                              -> { add.call("fl", LARGE - SMALL) },
                              "files#index (folder)")
    end
```

Run `bin/rails test test/integration/web/page_query_budget_test.rb -n /files#index/` → PASS. **Mutation:** move `@folder_project` out of `#index` and into the view as `current_user.maker_projects.find_by(folder_node_id: node.node_id)` inside the folder-row loop of `files/_grid.html.erb`; run → FAILS (grows with N). Restore; PASS. Report both.

- [ ] **Step 13: mutation checks — three more.**
  1. In `claim_on`, scope the lookup with `.where.not(status: "archived")`; run `project_adoptions_test.rb` → FAILS on "a folder an existing project claims is refused, archived included". Restore.
  2. In `refusal_for`, delete the `Library::WorkingTree` block; run → FAILS on "a folder inside a working tree that is not its root is refused". Restore, then also confirm "a folder that IS a git working tree can be adopted" is still green — the two together prove the refusal discriminates rather than blanket-refusing.
  3. In `dismiss_auto_model`, drop the `origin: "auto"` condition; run → FAILS on "an import model over the adopted folder is left alone". Restore. Report all six outputs, plus step 12's two.

- [ ] **Step 14: commit.**

```bash
git add app/controllers/projects/adoptions_controller.rb config/routes.rb app/controllers/files_controller.rb app/views/files/index.html.erb test/integration/web/project_adoptions_test.rb test/integration/web/files_toolbar_test.rb test/integration/web/page_query_budget_test.rb
git commit -m "A folder anywhere in the library can be made a project, and it keeps its path"
```

- [ ] **Step 15: hand Task E its sentences.** `docs/invariants/project-intake.md` needs a second door beside the discovery sweep, with its refusals and the `autofile: false` decision. `docs/invariants/model-intake.md`'s "A FOLDER A PROJECT CLAIMS IS THE PROJECT'S" bullet now has a second way for a project to claim a folder, and the adoption door dismisses the auto model rather than leaving it to Prune.

---

### Task D: the form, the flashes, the badge and "Not a project"

**Files:**
- Modify: `app/controllers/projects_controller.rb`, `app/controllers/concerns/current_project.rb`, `app/controllers/current_project_controller.rb`, `app/views/projects/_form.html.erb`, `app/views/projects/_card.html.erb`, `app/views/projects/show.html.erb`, `app/assets/stylesheets/components.css`
- Test: `test/integration/web/projects_flow_test.rb`, `test/controllers/current_project_controller_test.rb`, `test/integration/web/home_test.rb`, `test/css_hygiene_test.rb`

**Depends on Task A.** **`projects_controller.rb` and `_form.html.erb` are contended with S4-2's Task E** — take its committed state as the base.

- [ ] **Step 1: the failing form and create tests.** In `projects_flow_test.rb`, **replace** "the project form offers no status select" (`:329-334`) — that assertion is now false by design — and append the rest:

```ruby
    # STORY 1.2 / 1.6: "no status field on the form, so planning/active/paused/done are
    # unreachable — share: all 9 projects read planning". ASSERT THE RENDERED FIELD NAME, which is
    # §14d's twice-shipped `scope:` bug: a nested-hash POST bypasses the form entirely and cannot
    # see `maker_project[status]`.
    test "the project form offers a status select carrying the four live statuses" do
      sign_in
      get new_project_path
      assert_select "form.project-form select[name=?]", "project[status]"
      assert_select "form.project-form select[name='project[status]'] option[value=?]", "done"
      assert_select "form.project-form select[name='project[status]'] option[value=?]", "archived",
                    count: 0
      assert_select "select[name=?]", "maker_project[status]", count: 0
    end

    # ARCHIVING IS A BUTTON, AND THE SELECT MUST NOT BECOME A SECOND WAY OUT OF IT. With `archived`
    # absent from the options, a rendered select on an archived project would show nothing selected,
    # the browser would pick the first option, and saving any other field would silently unarchive
    # the project while leaving archived_at set.
    test "an archived project's form has no status select, and saving it leaves the status alone" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived",
                                            archived_at: Time.current)

      get edit_project_path(project)
      assert_select "select[name=?]", "project[status]", count: 0

      patch project_path(project), params: { project: { name: "Old Rig II" } }
      assert_equal "archived", project.reload.status
      assert_not_nil project.archived_at
    end

    # A hand-posted `archived` would set the column WITHOUT archived_at, so the archived list would
    # show a project the unarchive flow cannot reason about. The form never offers it; this closes
    # the door behind it.
    test "a hand-posted archived status is dropped rather than applied" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "active")

      patch project_path(project), params: { project: { name: "Desk Lamp", status: "archived" } }

      assert_equal "active", project.reload.status
    end

    # STORY 1.2: "Does not set current." The box is on `new` only — the edit page already has a
    # "Set as current" button, and an edit submit that silently switched the current project would
    # be a side effect nobody asked for.
    test "the new form offers make-current, checked, and the edit form does not" do
      user = sign_in
      get new_project_path
      assert_select "form.project-form input[type=checkbox][name=?][checked=?]",
                    "project[make_current]", "checked"

      get edit_project_path(user.maker_projects.create!(name: "Desk Lamp"))
      assert_select "input[name=?]", "project[make_current]", count: 0
    end

    test "creating with make-current sets it, and the flash names the folder and the destination" do
      sign_in
      post projects_path, params: { project: { name: "Smart Lamp", status: "active",
                                               make_current: "1" } }

      project = Maker::Project.find_by!(slug: "smart-lamp")
      assert_equal project.id, session[:current_project_id]
      assert_match(/Its folder is Projects\/smart-lamp\./, flash[:notice].to_s)
      assert_match(/Current project: Smart Lamp/, flash[:notice].to_s)
    end

    # `check_box_tag` emits NO hidden "0" companion, so an unchecked box sends nothing at all —
    # which is the right meaning here (absent = no) and is why this needs no hidden field.
    test "creating without make-current leaves the current project alone" do
      sign_in
      post projects_path, params: { project: { name: "Quiet Build", status: "planning" } }
      assert_nil session[:current_project_id]
      refute_match(/Current project/, flash[:notice].to_s)
    end

    # STORY 1.2: "A failed mkdir still says 'Project created.'" — the one flash a maker cannot act
    # on, over a project whose folder does not exist. The error CLASS is named because
    # FileLayer::FetchError (an unmounted NAS) and FileLayer::UnsupportedOperation (a refused name)
    # are different problems with different answers.
    test "a project whose folder could not be made says so, and names the error class" do
      sign_in
      raiser = ->(*) { raise FileLayer::FetchError, "library unavailable" }
      Maker::Project.define_method(:ensure_library_folder!, &raiser)
      begin
        post projects_path, params: { project: { name: "No Folder" } }
      ensure
        Maker::Project.remove_method(:ensure_library_folder!)
      end

      assert_predicate Maker::Project.find_by(slug: "no-folder"), :present?
      assert_match(/could not be made \(FileLayer::FetchError\)/, flash[:notice].to_s)
    end
```

**Note on the last test:** `Maker::Project#ensure_library_folder!` is defined on the class itself, so `define_method` + `remove_method` restores it exactly; do **not** reach for `#replacing`, which is written for SINGLETON methods. The existing test "project create still succeeds if the library backend can't make the folder" (`:115`) already fails the ensure a different way — read it first and reuse its mechanism if it is cleaner.

- [ ] **Step 2: run, expect failures.** `bin/rails test test/integration/web/projects_flow_test.rb` → FAIL on the missing `select[name='project[status]']`, the missing checkbox, `assert_nil session[:current_project_id]` inverted, and the flash matches.

- [ ] **Step 3: the form.** In `app/views/projects/_form.html.erb`, after the Description field and before Tags:

```erb
  <%#
    STATUS, BACK ON THE FORM (stage 4, S4-6; stories 1.2 and 1.6). Stage 3's decision #1 removed it
    because nothing read it; the measured library then showed all nine projects reading "planning"
    forever, with "done" unreachable from the web at all. The v1 API and the desktop app have
    always seen the full vocabulary, so this exposes what the column already holds.

    `archived` IS NOT AN OPTION, and it must not become one. Archiving is a button that also stamps
    archived_at; a select value would set the column without the timestamp. On an archived project
    the whole field is omitted rather than rendered with nothing selected — a browser then picks the
    first option, and saving any other field would silently unarchive the project. See
    ProjectsController#project_params, which drops the value even if one is hand-posted.
  %>
  <% unless project.status == "archived" %>
    <label class="field">
      <span>Status</span>
      <%= f.select :status,
                   options_for_select((Maker::Project::STATUSES - [ "archived" ]).map { |s| [ s.humanize, s ] },
                                      project.status) %>
    </label>
  <% end %>
```

and, directly above `.form-actions`:

```erb
  <% unless project.persisted? %>
    <%#
      MAKE IT CURRENT (stage 4, S4-6; story 1.2). "New project" minted the folder and then left the
      maker's next LightBurn save going somewhere else. Default ON, because a project you just
      created is the one you are about to work in.

      `check_box_tag`, NOT `f.check_box`, and STRIPPED IN project_params rather than permitted —
      the shape `project[cover_clear]` below already uses. There is no `make_current` attribute on
      Maker::Project and inventing one for a form is a model change nothing else would read. It
      emits no hidden "0" companion, which is correct here: absent means no, the box exists only on
      `new`, and there is no stored value an unchecked box has to clear.

      ON `new` ONLY. The edit page's header already carries a "Set as current" button, and an edit
      submit that switched the current project as a side effect would be exactly the silent change
      story 1.5 is about.
    %>
    <label class="field-inline">
      <%= check_box_tag "project[make_current]", "1", true %>
      Make this the current project
      <span class="field-hint muted">Uploads and tool output will land here.</span>
    </label>
  <% end %>
```

- [ ] **Step 4: the controller.** In `ProjectsController`:

(a) `#create`:

```ruby
  def create
    @project = current_user.maker_projects.new(project_params)
    if @project.save
      failure = ensure_project_folder(@project)
      make_current(@project) if params[:project][:make_current] == "1"
      redirect_to project_path(@project), notice: created_notice(@project, failure)
    else
      render :new, status: :unprocessable_entity
    end
  end
```

(b) `#show` — as the very first statement, before any of the loading:

```ruby
    # FIRST OPEN (stage 4, S4-6; stories 1.1 and 4.4). Stamped once, here, because this action is
    # already scoped to `current_user.maker_projects` — the owner is the only person who can reach
    # it, so there is no "whose view was this" to ask. Paired with `discovered_at`, it is the "New"
    # badge: the app made this and I have not looked at it yet.
    #
    # `update_column`: no validation, no callback, and NO `updated_at` BUMP — deliberately. Both
    # projects#index and Home order by `updated_at`, so bumping it would make merely OPENING a
    # project reorder every list, which is a change nobody asked for wearing a feature.
    #
    # A WRITE ON A GET, and an established one here: ensure_library_folder! below already writes
    # folder_node_id on this same render, and ThumbnailMap backfills. It runs at most once per
    # project ever, and page_query_budget_test.rb's warm-up render absorbs it.
    @project.update_column(:opened_at, Time.current) if @project.opened_at.nil?
```

(c) `#destroy` — the write is untouched; only the sentence branches:

```ruby
  # Soft archive — the model's lifecycle op (keeps the record + its history). Hard delete is a
  # deliberately deferred secondary affordance.
  #
  # "NOT A PROJECT" AND "ARCHIVE" ARE ONE WRITE AND TWO SENTENCES (stage 4, S4-6; story 1.6).
  # Archiving IS the dismissal mechanism — the claim lookup in Maker::ProjectDiscovery#adoptable is
  # unscoped, so an archived project keeps folder_node_id and the sweep passes over its folder
  # forever (docs/invariants/project-intake.md). That was true and undocumented; the maker had to
  # discover that "Archive" also meant "stop offering me this folder". A SECOND ROUTE performing
  # the same write would be the drift this codebase refuses, so `dismiss` changes the FLASH and
  # nothing else — the write is identical by construction, not by two callers agreeing.
  def destroy
    dismissing = params[:dismiss] == "1"
    @project.archive!
    notice = if dismissing
      "“#{@project.name}” is not a project. Its folder stays in your library, and the app " \
      "won't adopt it again."
    else
      "Archived #{@project.name}."
    end
    redirect_to projects_path, notice:
  end
```

(d) `#ensure_project_folder` returns the failure instead of swallowing it, and the two new private helpers:

```ruby
  # Best-effort: a project MUST save even if the library backend can't make its folder right now
  # (unmounted NAS, bucket blip). The folder is re-ensured on the next upload.
  #
  # IT RETURNS THE FAILURE NOW RATHER THAN SWALLOWING IT (stage 4, S4-6; story 1.2). "Project
  # created." over a folder that was never made is the one flash a maker cannot act on: the next
  # save from LightBurn goes to a directory that does not exist, and the only record was a log
  # line. The CLASS NAME is what the sentence carries, because FileLayer::FetchError (try again)
  # and FileLayer::UnsupportedOperation (never succeeds on retry) are different problems.
  def ensure_project_folder(project)
    project.ensure_library_folder!(current_user)
    nil
  rescue StandardError => e
    Rails.logger.warn("[projects] folder ensure failed for #{project.slug}: #{e.class} #{e.message}")
    e.class.name
  end

  # THE FOLDER IS NAMED FROM THE SLUG, NOT LOOKED UP — and that is exact rather than approximate
  # HERE and only here: #create always reaches ensure_library_folder!'s minting branch (a brand-new
  # project has no folder_node_id), and that branch builds [ROOT, slug] literally. A project ADOPTED
  # in place never comes through this action, so no sentence built here can name the wrong path.
  def created_notice(project, failure)
    lead = if failure
      "Project created, but its folder could not be made (#{failure}). It will be retried the " \
      "next time you upload."
    else
      "Project created. Its folder is #{Maker::ProjectFolders::ROOT}/#{project.slug}."
    end
    session[:current_project_id] == project.id ? "#{lead} #{current_project_notice(project)}" : lead
  end

  def make_current(project)
    session[:current_project_id] = project.id
  end
```

(e) `project_params` — drop an archived status:

```ruby
    # ARCHIVING IS A BUTTON, NOT A FORM VALUE (stage 4, S4-6). #archive! also stamps archived_at,
    # and the form's own select never offers `archived` — so a hand-posted one would set the column
    # WITHOUT the timestamp, leaving a row in the archived list that #unarchive cannot reason about.
    # Stripped rather than un-permitted, because the other four values are legitimate.
    attrs.delete(:status) if attrs[:status] == "archived"
```

(`:status` is already permitted — `projects_controller.rb:405`. `make_current` is never permitted; it is read straight off `params[:project]`, exactly as `cover_clear` is.)

- [ ] **Step 5: the current-project sentence, defined once.** In `app/controllers/concerns/current_project.rb`, beside `#current_project_folder_node_id`:

```ruby
  # WHAT A SWITCH JUST DID, IN ONE SENTENCE, IN ONE PLACE (stage 4, S4-6; stories 1.5 and 4.5).
  # Setting the current project changes where the next upload and the next tool save LAND, and the
  # app said nothing at all — no flash on any branch of CurrentProjectController, on a control that
  # sits in the rail, the top bar and the project page. Three doors set it, so the sentence has one
  # definition rather than three that drift, which is the same reading
  # ProjectFolderIntake#project_intake_sentence records for the collision clause.
  #
  # `nil` IS THE CLEARED CASE and gets its own half, because "no current project" is a destination
  # too — the library root — and a maker who cleared it needs to know that is where uploads go now.
  def current_project_notice(project)
    return "No current project — uploads go to the library root." if project.nil?

    "Current project: #{project.name} — uploads and tool output land there."
  end
```

Add `current_project_notice` to the `helper_method` list only if a view needs it — it does not today, so leave the list alone and say so in the comment if you prefer.

- [ ] **Step 6: the current-project controller.** Rewrite `CurrentProjectController`, keeping the existing behaviour of every branch and adding only the sentence:

```ruby
  # PATCH /current_project { project_id }. A present, owned id becomes current; a blank id clears
  # (so the top-bar "— none —" option flows through here too); a foreign/unknown id is ignored.
  #
  # EVERY BRANCH SAYS WHAT HAPPENED (stage 4, S4-6; story 1.5). This action changed where a
  # maker's next upload would land and redirected silently, on all three branches.
  def update
    id = params[:project_id].presence
    if id.nil?
      session.delete(:current_project_id)
      redirect_back_or_to files_path, notice: current_project_notice(nil)
    elsif (project = current_user.maker_projects.where.not(status: "archived").find_by(id: id))
      # archived projects can't be current — the read side (CurrentProject#current_project) filters them too
      session[:current_project_id] = project.id
      redirect_back_or_to files_path, notice: current_project_notice(project)
    else
      # NOT CLEARED, AND NOT NAMED. This branch has always fallen through leaving the session
      # untouched, which is right: a stale <option> or a forged id must not knock out a working
      # choice. The message names neither ownership nor existence — "that project is not yours"
      # would disclose that the id exists — and it is an ALERT, because nothing happened.
      redirect_back_or_to files_path,
                          alert: "That project isn't available — it may be archived or gone. " \
                                 "Your current project is unchanged."
    end
  end

  # DELETE /current_project — the explicit clear (top-bar "×" / project-page "Clear").
  def destroy
    session.delete(:current_project_id)
    redirect_back_or_to files_path, notice: current_project_notice(nil)
  end
```

- [ ] **Step 7: the failing current-project tests.** Append to `test/controllers/current_project_controller_test.rb`:

```ruby
  # STORY 1.5 / 4.5: "a switch gives no confirmation". Every branch, because the branch that says
  # nothing is the one a maker will hit and misread.
  test "every switch says what it did" do
    project = @user.maker_projects.create!(name: "Lamp")

    patch current_project_path, params: { project_id: project.id }
    assert_match(/Current project: Lamp — uploads and tool output land there\./, flash[:notice].to_s)

    patch current_project_path, params: { project_id: "" }
    assert_match(/No current project — uploads go to the library root\./, flash[:notice].to_s)

    delete current_project_path
    assert_match(/No current project/, flash[:notice].to_s)
  end

  # NOT A 500, NOT A SILENT CLEAR, AND NOT A DISCLOSURE. The session must survive untouched.
  test "an id that resolves to nothing alerts and leaves the choice alone" do
    mine = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: mine.id }

    other = User.create!(email: "cp-x-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    foreign = other.maker_projects.create!(name: "Theirs")

    patch current_project_path, params: { project_id: foreign.id }

    assert_equal mine.id, session[:current_project_id], "a foreign id must not clear a real choice"
    assert_match(/isn't available/i, flash[:alert].to_s)
    refute_match(/Theirs/, flash[:alert].to_s + flash[:notice].to_s)
  end

  test "an archived project cannot become current and says so" do
    archived = @user.maker_projects.create!(name: "Old Rig", status: "archived")
    patch current_project_path, params: { project_id: archived.id }
    assert_nil session[:current_project_id]
    assert_match(/isn't available/i, flash[:alert].to_s)
  end
```

The pre-existing "update ignores a project that is not the user's own" (`:26`) still passes — it asserts `assert_nil session[:current_project_id]` starting from an empty session, and this branch still writes nothing.

- [ ] **Step 8: the New badge and the status badge.** In `app/views/projects/_card.html.erb`, inside the `.project-tile`, directly after the `link_to project_path` block:

```erb
  <%#
    NEW (stage 4, S4-6; story 1.1). An auto-created project the owner has not opened yet — the only
    feedback discovery has ever had, and the one that works on every backend and for the unattended
    15-minute sweep, which is how discovery actually runs. Both columns come off the row this card
    already holds, so the badge costs no query on the index or on Home.

    `discovered_at.present?` IS the definition of auto-created: Maker::ProjectDiscovery is the only
    writer, and Projects::AdoptionsController leaves it nil on purpose (a project you made is never
    new to you). It clears itself on the first open — ProjectsController#show stamps `opened_at` —
    so nothing has to be dismissed and no state accumulates.
  %>
  <% if project.discovered_at.present? && project.opened_at.nil? %>
    <span class="badge project-new">New</span>
  <% end %>
```

In `app/views/projects/show.html.erb`, inside `.page-title`, after the archived-badge block:

```erb
  <%#
    THE STATUS, WHERE IT CAN BE SEEN (stage 4, S4-6; story 1.6). The form can set it again, and a
    value nobody can see is a field nobody will use. `planning` is the column default and badging a
    default is noise — the same argument S4-1's quiet panels make about a zero. `archived` keeps its
    own badge above; this covers active, paused and done.
  %>
  <% if @project.status.in?(%w[active paused done]) %>
    <span class="badge status-<%= @project.status %>"><%= @project.status.humanize %></span>
  <% end %>
```

and in `.head-actions`, immediately before the Archive `button_to`:

```erb
      <% if @project.discovered_at.present? %>
        <%#
          NOT A PROJECT (stage 4, S4-6; story 1.6). The app made this row from a folder, so the
          maker needs a way to say it was wrong — and archiving already IS that mechanism, silently:
          the claim lookup is unscoped, so an archived project keeps its folder_node_id and the
          sweep passes over that folder forever. This names the act instead of leaving it to be
          discovered. ONE WRITE, TWO SENTENCES — see ProjectsController#destroy; a second route
          would be two ways to do one thing.

          Only for a discovered project: a project you made by hand was never adopted, so there is
          nothing for "not a project" to mean.
        %>
        <%= button_to "Not a project", project_path(@project, dismiss: 1), method: :delete,
                      class: "btn small ghost",
                      form: { data: { turbo_confirm: "“#{@project.name}” is not a project? Its folder stays in your library, and the app won't adopt it again." } } %>
      <% end %>
```

and extend the Archive button's confirm so the undocumented half is documented at the point of the click. Build the sentence in a local **above** the `.head-actions` div — one call site, so no helper method:

```erb
<% archive_confirm = if @project.discovered_at.present?
     "Archive #{@project.name}? Its folder stays in your library, and the app won't adopt it as a project again."
   else
     "Archive #{@project.name}?"
   end %>
```

and use it in the existing button, replacing only the `turbo_confirm:` value:

```erb
      <%= button_to "Archive", project_path(@project), method: :delete, class: "btn small danger",
                    form: { data: { turbo_confirm: archive_confirm } } %>
```

- [ ] **Step 9: the CSS.** In `app/assets/stylesheets/components.css`, beside the other badge variants (after `.badge.status-archived`, `:170`):

```css
  /* --- Project status and the new-project mark (stage 4, S4-6). Variants of `.badge`, so they
     live HERE and nowhere else: a component selector is defined in components.css alone
     (design-system rule 3), and `pages/projects.css` may qualify one inside a container but never
     redeclare it. `planning` has no rule because it is the default and is never badged. --- */
  .badge.status-active { background: var(--accent-soft); color: var(--accent); }
  .badge.status-paused { background: var(--raised); color: var(--fg-muted); }
  .badge.status-done { background: color-mix(in srgb, var(--ok) 16%, transparent); color: var(--ok); }
  .badge.project-new { background: var(--accent-soft); color: var(--accent); text-transform: none; }
```

- [ ] **Step 10: the badge tests.** Append to `projects_flow_test.rb`:

```ruby
    # STORY 1.1: "no 'new' marker". The badge is the surface on every backend, including for the
    # unattended sweep, which is the only way discovery runs on share/s3.
    test "an auto-created project wears a New badge until its owner opens it" do
      user = sign_in
      auto = user.maker_projects.create!(name: "Tray")
      auto.update_columns(discovered_at: 1.hour.ago)
      user.maker_projects.create!(name: "By Hand")

      get projects_path
      assert_select ".project-tile .badge.project-new", count: 1

      get project_path(auto)
      assert_not_nil auto.reload.opened_at

      get projects_path
      assert_select ".badge.project-new", count: 0
    end

    # `update_column`, so opening a project must NOT reorder the lists that sort by updated_at.
    # Compared with a three-day gap rather than at second resolution: §15 records that a timestamp
    # asserted at `.to_i` was written in the same second as the thing it feared, so the mutation
    # stayed green.
    test "opening a project does not touch updated_at" do
      user = sign_in
      project = travel_to(3.days.ago) { user.maker_projects.create!(name: "Tray") }
      before = project.reload.updated_at

      get project_path(project)

      assert_equal before.to_f, project.reload.updated_at.to_f
      assert_not_nil project.opened_at
    end

    test "the status is badged on the page unless it is the default" do
      user = sign_in
      get project_path(user.maker_projects.create!(name: "A", status: "planning"))
      assert_select ".page-title .badge", text: "Planning", count: 0

      get project_path(user.maker_projects.create!(name: "B", status: "done"))
      assert_select ".page-title .badge.status-done", text: "Done"
    end

    # STORY 1.6: "Archive doubles as the undocumented 'not a project' dismissal."
    test "a discovered project offers Not a project, and it archives with its own sentence" do
      user = sign_in
      auto = user.maker_projects.create!(name: "Tray")
      auto.update_columns(discovered_at: 1.hour.ago)

      get project_path(auto)
      assert_select ".head-actions form[action=?] button", project_path(auto, dismiss: 1),
                    text: "Not a project"
      assert_select ".head-actions form[data-turbo-confirm*=?]", "won't adopt it as a project again"

      delete project_path(auto, dismiss: 1)
      assert_equal "archived", auto.reload.status
      assert_match(/is not a project/i, flash[:notice].to_s)
      assert_match(/folder stays in your library/i, flash[:notice].to_s)
    end

    test "a hand-made project offers Archive only, with the plain confirm" do
      user = sign_in
      project = user.maker_projects.create!(name: "By Hand")

      get project_path(project)
      assert_select "form[action=?]", project_path(project, dismiss: 1), count: 0
      assert_select ".head-actions form[data-turbo-confirm=?]", "Archive By Hand?"

      delete project_path(project)
      assert_match(/^Archived By Hand\./, flash[:notice].to_s)
    end
```

and to `test/integration/web/home_test.rb`, beside the existing recent-projects assertions (its Projects section is `.home-projects .tile-row .project-tile`, `:74-84`):

```ruby
    # The same partial, so Home gets discovery's feedback for free — and this is what Home gets
    # from S4-6 instead of an adopt door (there is no folder on this page to adopt).
    test "Home badges an auto-created project the owner has not opened" do
      project = @user.maker_projects.create!(name: "Tray")
      project.update_columns(discovered_at: 1.hour.ago)

      get root_path

      assert_select ".home-projects .project-tile .badge.project-new", text: "New"
    end
```

- [ ] **Step 11: run everything this touches.**

```bash
bin/rails test test/integration/web/projects_flow_test.rb test/controllers/current_project_controller_test.rb test/integration/web/current_project_topbar_test.rb test/integration/web/current_project_set_from_project_test.rb test/integration/web/current_project_files_upload_test.rb test/integration/web/home_test.rb test/integration/web/project_page_test.rb test/integration/web/project_attachments_test.rb test/integration/web/files_toolbar_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/integration/web/page_query_budget_test.rb test/system/home_test.rb
```

Two pre-existing assertions need reading, not necessarily changing:
- `projects_flow_test.rb:313` "the detail page shows no status badge for a live project" builds its project with `status: "paused"` and asserts only `.badge.status-archived, count: 0`. That still passes, but it now passes over a page that DOES badge — change its fixture to `status: "planning"` and add `assert_select ".page-title .badge", count: 0`, or the assertion no longer means what its name claims.
- `projects_flow_test.rb:349` "a live project's detail page offers archive, not unarchive" uses `assert_select "form[action=?]", project_path(project)` with no count, so a Not-a-project button beside it would not break it — but its fixture is hand-made (`discovered_at` nil), so the second form does not render at all. Leave it.

- [ ] **Step 12: mutation checks — five.**
  1. In `#show` change `if @project.opened_at.nil?` to `if false`; run `projects_flow_test.rb -n /New badge/` → FAILS on `assert_select ".badge.project-new", count: 0` (the badge never clears). Restore.
  2. In `#show` change `update_column` to `update!`; run → FAILS on "opening a project does not touch updated_at". Restore.
  3. In `_form.html.erb` drop the `unless project.status == "archived"` guard; run → FAILS on "an archived project's form has no status select". Restore.
  4. In `project_params` delete the `attrs.delete(:status)` line; run → FAILS on "a hand-posted archived status is dropped". Restore.
  5. In `CurrentProjectController#update`'s `else` branch add `session.delete(:current_project_id)`; run `current_project_controller_test.rb` → FAILS on "a foreign id must not clear a real choice". Restore. Report all ten outputs.

- [ ] **Step 13: commit.**

```bash
git add app/controllers/projects_controller.rb app/controllers/concerns/current_project.rb app/controllers/current_project_controller.rb app/views/projects/_form.html.erb app/views/projects/_card.html.erb app/views/projects/show.html.erb app/assets/stylesheets/components.css test/integration/web/projects_flow_test.rb test/controllers/current_project_controller_test.rb test/integration/web/home_test.rb
git commit -m "Creating a project says what it did, a switch says where things will land, and an auto-created project says it is new"
```

- [ ] **Step 14: hand Task E its sentences.** `docs/invariants/project-intake.md`'s dismissal bullet ("THE CLAIM LOOKUP IS UNSCOPED, AND THAT IS THE ENTIRE DISMISSAL MECHANISM") now has a named button in front of it and must say so.

---

### Task E: the phone sweep, the documents, the close-out

**Files:** `test/system/shell_test.rb`, `docs/invariants/project-intake.md`, `docs/invariants/model-intake.md`, `docs/user-stories.md`, `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`

**After B, C and D have committed.**

- [ ] **Step 1: the phone sweep visits a folder view.** `test/system/shell_test.rb`'s fixture already holds `folder` — the project's `Projects/desk-lamp` dir node, with real bytes under it (`:118-121`, `:156`, `:166-169`). Add one entry to the sweep array at `:273`, after `files_path(view: "grid")`:

```ruby
        files_path(folder: folder.node_id),
```

and inside the per-page block, beside the other gated legs:

```ruby
        if path == files_path(folder: folder.node_id)
          # STAGE 4, S4-6: the folder view's own head, with the overflow menu the adopt door lives
          # in. This folder IS a project's, so the menu offers the project rather than the verb —
          # which is the arm that renders a longer label and is therefore the one worth measuring
          # at 375px. `details.menu` is closed, so the assertion is that the summary is reachable.
          assert_selector ".page-actions details.menu summary.btn", visible: true
          visited_folder_view = true
        end
```

with `visited_folder_view = false` declared beside `launched_gerber`/`opened_repo` (`:268-272`) and asserted after the loop, exactly as those two are — **the flag is what makes a renamed helper a failure rather than a quieter test** (`:265-272` argues this at length for the Gerber leg).

- [ ] **Step 2: run it.** `bin/rails test:system TEST=test/system/shell_test.rb` → PASS, with no page scrolling sideways at 375px. **Mutation:** in `files/index.html.erb` set `menu_items` back to `capabilities.scannable? || current_project.present?`; on a chunk_remote leg the folder view then renders no menu and the new assertion goes RED. On the share leg it stays green (share is scannable), so run this mutation on `bin/ci test-chunk-remote` or note that it is leg-dependent and report which leg you drove. Restore.

- [ ] **Step 3: `docs/invariants/project-intake.md`.** Under "Discovery — a folder under `Projects/` becomes a project", add four things and amend one:

  - **A second door, and what it may and may not do.** `Projects::AdoptionsController` adopts ONE folder anywhere in the library. It shares this sweep's name rule through `Maker::ProjectDiscovery.adoptable_name?` rather than spelling one; it takes the same `Maker::Project.available_slug`; it never calls the port and never calls `ensure_library_folder!`; and it refuses seven ways — no id, not a live dir, a dot name, the `Projects/` root, a folder any project already claims (**unscoped on status**, so archiving still dismisses), a folder inside another project's folder, and a folder strictly inside a working tree. **The strictness is the point in both directions:** a repository ROOT is adoptable (`Library::WorkingTree#root_for` starts at the parent), and refusing a repository's `src/` is what stops a project whose README, commits and history sit outside its own folder.
  - **`discovered_at` is this sweep's own mark, and nothing else writes it.** The adoption door leaves it nil deliberately, which is what makes `discovered_at.present?` mean "the app made this".
  - **An adopted project is created with `autofile: false`, and discovery's stays `true`.** State the asymmetry and the argument: a folder under `Projects/` asked for the app's filing by being there; a folder in `designs/` did not, and re-filing it fifteen minutes after the maker said "this is a project" is the fight-the-user failure this file already forbids one directory level down.
  - **The scan door now runs discovery on `chunk_remote`,** between the pull and the intake, via `Maker::ProjectDiscoveryJob.perform_now` — with the `limits_concurrency`-at-enqueue gap named, and the `rate_limit` as what bounds it.
  - **Amend the dismissal bullet.** "THE CLAIM LOOKUP IS UNSCOPED, AND THAT IS THE ENTIRE DISMISSAL MECHANISM" is still true and is no longer undocumented to the user: `ProjectsController#destroy` takes `dismiss=1`, which changes the sentence and not the write, and the project page renders "Not a project" beside Archive for a discovered project.

- [ ] **Step 4: `docs/invariants/model-intake.md`.** Amend "A FOLDER A PROJECT CLAIMS IS THE PROJECT'S, NOT THE CATALOG'S": there are now **two** ways a project comes to claim a folder — the sweep and the adoption door — and the door additionally **dismisses** an `origin: "auto"` model whose `auto_node_id` is that folder, in the same transaction. Say why: `for_user` drops a claimed key before `existing` is looked up, so accretion stops at once, but the ROW SURVIVES (that method's own comment says clearing it is `Prune`'s job) — which would leave `designs/tray` a project and a model at the same time, the exact friction story 1.3 measured. Dismissed and not destroyed, because the row is the memory in both directions; **auto only**, because nothing recreates an import model so a dismissal has nothing to say to the sweep.

- [ ] **Step 5: re-tag the stories** in `docs/user-stories.md`, with the new evidence in the last column, and update the Coverage table:
  - **1.1** → `rough`: discovery stamps `discovered_at` and a **New** badge sits on the card until first open, on the index and on Home, on every backend (S4-6); the chunk_remote scan button names the folders it adopted. Still rough: on share/s3 the scan is a background job, so the flash cannot name them, and the slug/folder-name divergence stands.
  - **1.2** → `works`: the form carries status and "make current" (default on); the flash names `Projects/<slug>`, or names the error class when the folder could not be made (S4-6, `projects_controller.rb#created_notice`).
  - **1.3** → `rough` (from `missing`): `POST /projects/adopt` makes any folder a project in place, and an auto model over that folder is dismissed in the same transaction (S4-6). Still rough: no folder rename or move from the web, and the door is on the Files page only.
  - **1.5** → `rough` (from `missing`): creation, current-project switches and the chunk_remote scan all report; S4-2 landed the filing half. Still rough: cover selection is silent, and share/s3 discovery reports only through the badge.
  - **1.6** → `rough`, new evidence: status is settable and badged, and "Not a project" is an explicit action with its own sentence beside Archive (S4-6). Still rough: rename never renames the folder or the slug — deliberate (stage 3 decision 2), and the form now says so.
  - **4.5** → `works`: a switch confirms on every branch and names the destination (S4-6, `CurrentProject#current_project_notice`).
  - **4.7** → `rough`, new evidence: a folder can become a project from the Files page in one click (S4-6). Still rough: a loose screenshot at the library root still has no "file into project X" action — that is the file-level half, unmoved.

- [ ] **Step 6: the overview.** In `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`, mark the S4-6 row landed with its PR number, **and correct the "S4-2, S4-3, S4-5 and S4-6 are independent" sentence** — S4-6 depends on S4-2 for `maker_projects.autofile` (amendment 1). Also add `Maker::ProjectDiscovery.adoptable_name?` to the "Shared interfaces" section, since S4-7 and anything else minting a project folder will want it.

- [ ] **Step 7: the gates.** `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` green; the three legs' run counts identical (a ±2 assertion flap is `tinkerex#131`; anything structural is a bug — and this slice adds no backend-conditional test, so a structural split means a fixture reached the port).

- [ ] **Step 8: commit, push, PR, record.** `git commit -m "S4-6 close-out: the stories re-tagged, the invariants amended, the overview corrected"`; `/finish-branch`; then `bin/log arc --from-pr <n>`.

---

## Self-review against the spec (§5's S4-6 row and §2's D1)

| spec item | task | note |
|---|---|---|
| adopt in place: a folder anywhere becomes a project, keeps its path, `folder_node_id` points there | C steps 1–5 | nothing downstream changed; three existing readers already resolve from the column |
| "Make this folder a project" **on the Files page** | C steps 9–10 | in the existing `details.menu`, on the folder view only |
| …**and Home** | — | **deliberately dropped, amendment 2**: Home renders projects, not folders |
| discovery keeps its rules; adoption is a door, never a sweep; `Projects/` is never minted | B step 3, C step 5 | one shared name rule; the "mints no node" test asserts the whole node set is unchanged |
| the New project form gains **status** | D steps 3–4 | `archived` excluded from the options *and* dropped in `project_params` |
| …and **"make current" (default on)** | D step 3 | `check_box_tag`, `new` only — amendment 3 |
| …and its flash **names the folder** | D step 4(d) | plus the error class when the mkdir failed |
| a **New badge** on auto-created projects until first open | A, B step 3, D steps 4(b), 8 | `discovered_at` + `opened_at`, both unindexed, both read off loaded rows |
| the Scan button's flash **names what discovery created** | B steps 7 | chunk_remote only; the badge is the surface on share/s3 — amendment 5 |
| **"Not a project"** explicit and distinct from Archive | D steps 4(c), 8 | one write, two sentences — amendment 7 |
| a **confirmation on every current-project switch** | D steps 5–6 | including the ignored-id branch, which alerts and changes nothing — amendment 8 |
| `ensure_library_folder!`'s callers are no-ops for an adopted project | C step 3 | driven through the real page, not argued |
| the sweep files an adopted folder's loose files | C step 5 | it **would**, by construction; `autofile: false` is what stops it, on purpose — amendment 4 |
| the existing `Maker::Model` row for an adopted folder | C step 5 | dismissed (auto only), in the same transaction |
| query budgets constant in N for `projects#index`, Home and the Files folder view | C step 12, D step 11 | the folder-view budget is corrected to actually visit a folder |
| the template sweep renders the new branches | — | **no `template_hygiene_test.rb` edit**: no new partial, and its guard is per template |
| `architecture_invariants_test.rb`'s column obligations | A steps 1, 5 | no index on either timestamp, argued in the migration |
| the phone sweep visits the Files folder view with the menu | E steps 1–2 | with a flag, so the leg cannot go silently unrun |

## Open questions the implementer must not decide alone

1. **A partial unique index on `maker_projects (user_id, folder_node_id) WHERE folder_node_id IS NOT NULL`.** Two doors can now mint a project for one folder — discovery racing itself outside `limits_concurrency` (amendment 5) and two simultaneous adopt POSTs — and nothing in the database prevents it, exactly as `Maker::ProjectDiscoveryJob`'s own header records. `maker_models` already carries the equivalent index for `auto_node_id`, so the shape is settled; what is not settled is whether the live deployments hold a duplicate today, because a `add_index … unique:` migration over one **raises and takes the deploy down**. This needs a read-only probe of the three Unraid databases before it is written, which this slice cannot do. File it as open work; do not add the index here.
2. **What happens to an adopted project when its folder is deleted from the library.** `ensure_library_folder!` falls through to minting `Projects/<slug>` whenever `folder_node_id` names a tombstone (`project.rb:145-150`), so deleting `designs/tray` in Finder silently relocates the project into `Projects/`. That is today's behaviour for every project and this slice does not change it, but for an ADOPTED project it contradicts "it keeps its path" in a way nobody will expect. The alternatives are a `folder_origin` column (a second source of truth for a fact `folder_node_id` already holds — the shape §14f refuses), or making the ensure decline for a project whose folder was adopted, which needs a way to tell them apart. Decide it with the spec author before writing either.
3. **Whether a folder an IMPORT-origin model claims should be refusable.** This plan leaves it adoptable and simply does not touch the model row (amendment: the dismissal is auto-only), so `Models/enclosure` can be both a model and a project. That is a user choice and nothing breaks, but it is the one refusal the prompt's list did not name and the one place two catalogs can claim one folder deliberately. If it should be refused, it is one more `find_by` in `refusal_for` and one more test.
4. **Whether `discovery_sentence` should also fire on the `:capped` status.** A run that adopted 50 of 63 folders is worth saying out loud ("created 50 of 63") and `RunResult` already carries `candidates` and `cap` for exactly that. This plan says nothing about it, because the scan door's flash is already three sentences long and a capped run on a browser-facing door is a case nobody has measured. Cheap to add later; not decided here.
