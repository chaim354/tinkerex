# Stage 3, S3-1: the project view — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S3-1 of `docs/superpowers/specs/2026-09-04-stage-3-publishable-project-design.md` (§5). The project page's Files panel becomes **the folder as a tree**: sections are the folder's real subfolders (nested, collapsible), a repository is a section expandable in place, loose files at the root come first, a **Generated** group lists tool output with its tool, saved item and revision, Linked files follow; a **list/tiles toggle** remembered like the Files page's. The **extension map** the intake sweep files by becomes per-user (`/settings/filing`, seeded from today's eleven roles). Stray **`.ptr`** pointer stubs are hidden from every listing and swept by a rake task through the port. One new table; every page's query count stays constant in N.

**Architecture:** `Maker::FilingRule` (user, ext, folder) with `Maker::FilingRules.for(user)` seeding the eleven-role map on first read; `Maker::ProjectFolders.folder_for(user, name)` reads it, and the three callers pass the user. `Maker::ProjectFolderListing` grows a `tree` (dirs with children) and now ENTERS working trees, capped as before; the panel renders the tree with native `details`, the list view a `table.table`. `Maker::AddonOrigin.for` already resolves a node to its saved state; the Generated group reads it once for the page's node ids. `Node.visible_entries` gains the `.ptr` rule; `rake projects:sweep_pointers` deletes pointers through `FileLayer.current.delete` so they land in the trash.

**Tech Stack:** Rails 8 (one migration), Hotwire, Minitest, `page_query_budget_test.rb`, one rake task.

---

## Before you start

- Branch `claude/stage-3-project-view` from `main` at `bbd4a44` (stage 2 deployed); the spec is committed. Worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; commit with a pathspec (another agent shares the index). **The migration**: `bin/rails db:migrate` in development AND `RAILS_ENV=test bin/rails db:migrate` (or `db:prepare`) before the test runs; `db/schema.rb` is committed with it.
- **Read `docs/invariants/project-intake.md` first** (§14f): the sweep files loose ROOT files into subfolders named by the extension map; `destination_for` creates nothing; the folder names are NOT `ROLE_LABELS`; `fetch` with no default is the totality guard. Read `docs/invariants/files-preview.md` (`ROLE_BY_EXT` is the FILE-TYPE vocabulary the Files page filters by — it stays; the FILING map is what becomes per-user) and `docs/invariants/design-system.md`.
- `Maker::ProjectFolders.folder_for(name)` is called from `Maker::ProjectIntake` (twice) and `ProjectFolderIntake` (a flash sentence). `Library::ReservedNames.reserved?(name)` and `Maker::MoveNode.valid_leaf_name?(name)` are the two questions every door asks a folder name. `FilesController::EXT_RE = /\A[a-z0-9]{1,8}\z/`.
- Fixtures: a project folder is `project_folder_rows!(user, project)`; nodes are `@user.nodes.create!(node_id:, name:, kind:, parent_node_id:)`; a share library for a rake task that deletes is `use_fresh_share_library!` + `create_node!`. Never `ensure_library_folder!` in a request test.
- `git checkout -- <file>` cannot restore a new file: `git add` before a mutation check.

## File structure

| path | responsibility | task |
|---|---|---|
| `db/migrate/*_create_maker_filing_rules.rb`, `db/schema.rb`, `app/models/maker/filing_rule.rb`, `app/services/maker/filing_rules.rb`, `app/models/user.rb` (`has_many :maker_filing_rules`) | the per-user extension map | A |
| `app/services/maker/project_folders.rb` (`folder_for(user, name)`, `default_folder_for(name)`), `app/services/maker/project_intake.rb`, `app/controllers/concerns/project_folder_intake.rb` (pass the user) | the sweep obeys it | A |
| `app/controllers/settings/filing_rules_controller.rb`, `app/views/settings/filing_rules/index.html.erb`, `app/views/settings/show.html.erb` (a Filing row), `config/routes.rb` (`namespace :settings { resources :filing_rules, only: %i[index create update destroy], path: "filing" }`) | `/settings/filing` | A |
| `test/models/maker/filing_rule_test.rb`, `test/services/maker/filing_rules_test.rb`, `test/services/maker/project_folders_test.rb` (rewritten guard), `test/services/maker/project_intake_test.rb` (+ the custom-rule case), `test/integration/web/settings_filing_test.rb`, `settings_hub_test.rb` (the row), `page_query_budget_test.rb` (`settings/filing_rules#index`), `template_hygiene_test.rb`, `docs/invariants/project-intake.md`, `docs/invariants/files-preview.md` | A's tests and docs | A |
| `app/services/maker/project_folder_listing.rb` (`tree`, enters repos, `Loose`), `app/controllers/projects_controller.rb` (`#show`: view, generated, tree), `app/views/projects/_attachments.html.erb`, `_attachment_group.html.erb`, new `_file_tree_section.html.erb`, `_file_rows.html.erb` (list view), `_generated_group.html.erb`, `app/assets/stylesheets/pages/projects.css` | the panel | B |
| `app/models/node.rb` (`visible_entries` hides `*.ptr`), `lib/tasks/projects.rake` (`sweep_pointers`) | pointers | B |
| `test/services/maker/project_folder_listing_test.rb`, `test/integration/web/project_attachments_test.rb`, `project_page_test.rb`, `test/models/node_test.rb` (or the files test that pins `visible_entries`), `test/tasks/projects_sweep_pointers_test.rb` (new; see `test/tasks/` for the rake idiom), `test/system/projects_models_pages_test.rb` (the toggle) | B's tests | B |

**Dependencies:** A and B are disjoint; run in parallel. C (the orchestrator) closes out.

---

### Task A: the extension map, per user

- [ ] **Step 1: migration and model.**

```ruby
class CreateMakerFilingRules < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_filing_rules do |t|
      t.integer :user_id, null: false
      t.string :ext, null: false      # "stl" — lowercase, no dot, FilesController::EXT_RE
      t.string :folder, null: false   # "models" — one lowercase path segment, never reserved
      t.timestamps
    end
    add_index :maker_filing_rules, %i[user_id ext], unique: true
  end
end
```

`Maker::FilingRule`: `belongs_to :user`; `normalizes :ext, with: ->(e) { e.to_s.strip.downcase.delete_prefix(".") }`, `normalizes :folder, with: ->(f) { f.to_s.strip.downcase }`; `validates :ext, format: FilesController::EXT_RE` (reference the constant, do not copy the regex), `validates :folder, presence: true`, `validate :folder_is_a_plain_segment` (`Maker::MoveNode.valid_leaf_name?(folder) && !folder.include?("/") && !Library::ReservedNames.reserved?(folder)`), uniqueness of `ext` scoped to `user_id`.

`Maker::FilingRules`:

```ruby
module Maker
  # THE EXTENSION MAP, PER USER (stage 3, S3-1): which subfolder of Projects/<slug>/ the intake sweep
  # files each extension into. Seeded ONCE from the eleven-role default (ProjectFolders::ROLE_FOLDERS
  # over FileAttachment::ROLE_BY_EXT) on the first read, then the user's rows are the truth — the
  # seed is a starting point, never a fallback that would silently overrule an edit.
  class FilingRules
    def self.for(user) = new(user).to_h

    def self.seed!(user)
      return if user.maker_filing_rules.exists?
      now = Time.current
      rows = Maker::FileAttachment::ROLE_BY_EXT.map do |ext, role|
        { user_id: user.id, ext:, folder: Maker::ProjectFolders::ROLE_FOLDERS.fetch(role), created_at: now, updated_at: now }
      end
      Maker::FilingRule.insert_all(rows) if rows.any?
    end

    def initialize(user)
      self.class.seed!(user)
      @map = user.maker_filing_rules.pluck(:ext, :folder).to_h   # ONE query after the seed
    end

    def to_h = @map
  end
end
```

`Maker::ProjectFolders`: keep `ROOT`, `ROLE_FOLDERS`; `folder_for(user, name)` = `rules.fetch(ext_of(name), "other")` where `rules` is `Maker::FilingRules.for(user)` — **memoize per user per sweep**: the callers in `ProjectIntake` run in a loop, so give `ProjectIntake` one `@filing = Maker::FilingRules.for(user)` and a `folder_for(name)` private method reading it (not a query per file: the budget shape §14f's "memo is per parent" warns about). Keep `default_folder_for(name)` (today's pure function) for the seed and for callers with no user in hand. Update the three callers. **The totality guard changes meaning**: `project_folders_test.rb`'s "every role has a folder" stays (the seed needs it); add "an extension with no rule files into `other`"; "folder names are single lowercase path segments" now also asserts every SEED folder passes `FilingRule`'s own validation (so the seed can never write a row the form would refuse).

- [ ] **Step 2: the settings page.** Routes as in the table. `Settings::FilingRulesController`: `index` (`@rules = Maker::FilingRules.for(current_user)` sorted by ext — expose the records: `current_user.maker_filing_rules.order(:ext)` after `seed!`), `create` (`params.require(:filing_rule).permit(:ext, :folder)`), `update` (folder only), `destroy`; every refusal is a redirect with the model's message. View: `page-head` (h1 Filing, Back to Settings), a `p.muted` explaining "when a file lands loose in a project folder, the sweep files it into the subfolder its extension names; an extension with no rule goes to `other`", `ul.settings-list` rows (`span.settings-name.mono` `.stl`, an inline `form_with model: rule, scope: :filing_rule, url: settings_filing_rule_path(rule), method: :patch` with a small `text_field :folder` + Save, and Remove), an add form (`ext`, `folder`). The hub (`settings/show.html.erb`) gains a **Filing** row (`settings_filing_rules_path`, fact `pluralize(n, "rule")`) between Locations and Tags — and `settings_hub_test.rb`'s six-row assertion becomes seven.

- [ ] **Step 3: tests.** Model: normalization (`.STL` → `stl`), the regex, a reserved folder (`.trash`, `.maker-tmp-x`, `.git`) refused, a slash refused, uniqueness per user. Service: first read seeds exactly `ROLE_BY_EXT.size` rows and a second read seeds nothing; an edit survives a re-read; `folder_for(user, "part.STL")` reads the user's rule and `"x.zzz"` → `other`. Intake: in `project_intake_test.rb` (find its fixture idiom), a user whose rule says `stl → prints` gets a loose `bracket.stl` filed into `prints/`, not `models/`. Request (`settings_filing_test.rb`): the page lists the seeded rules, add/update/remove round-trips, a bad extension and a reserved folder are refused with the message, tenancy (a foreign rule 404s), rendered field names (`input[name='filing_rule[ext]']`). Budget: `settings/filing_rules#index` constant as rules grow. Template hygiene map entry. Docs: `project-intake.md` — the folder names come from the user's filing rules (seeded from the eleven roles), `folder_for` takes the user, and the guard sentence; `files-preview.md` — `ROLE_BY_EXT` is the type vocabulary and the SEED of filing, no longer the filing map itself.

- [ ] **Step 4: mutation-check** (stage first; verbatim; restore): (a) `folder_for` ignoring the user's rules (read `default_folder_for`) → the intake custom-rule test fails; (b) seed on EVERY read (drop the `exists?` guard) → "a second read seeds nothing" and the edit-survives test fail; (c) drop the reserved-name validation → the `.trash` test fails; (d) the controller unscoped (`Maker::FilingRule.find`) → the foreign-404 test fails.

- [ ] **Step 5: commit** with a pathspec: `The extension map is the user's: filing rules seeded from the eleven roles, edited at /settings/filing, obeyed by the sweep`.

---

### Task B: the folder as a tree, the list view, Generated, pointers

- [ ] **Step 1: the listing grows a tree and enters repositories.** In `Maker::ProjectFolderListing`: the walk no longer stops at a working tree — it enters it (still skipping dot-dirs, still `DIR_CAP`), and remembers which dirs are repo roots (`repo_root_ids`); `Repo` rows stay for the Repositories link targets. New: `tree` → an Array of `Dir = Data.define(:node_id, :name, :path, :repo?, :children, :files)` for the folder's DIRECT subfolders (each with nested `children` and its `files` as `Row`s), plus `loose` → the `Row`s at the folder root. Build both in memory from `files` (each row's `parent_node_id`) and the tree index; a dir with no files anywhere beneath it is still listed (an empty section reads "empty"). Order dirs by name, files by name. `contains?` unchanged. Tests: `tree` nests two levels; a repo dir is a `Dir` with `repo? == true` and its files listed; `loose` holds only root files; the cap still applies; an empty subfolder appears with no files; `Row#role` unchanged.

- [ ] **Step 2: the controller.** `ProjectsController#show`: `@view = resolve_project_view` (`params[:view]` in `%w[tiles list]` → cookie `project_view` for a year; default `tiles`); `@generated = Maker::AddonOrigin.for(user: current_user, node_ids: @listing.node_ids)` (ONE query; read `app/services/maker/addon_origin.rb` or wherever `AddonOrigin.for` lives for what a state carries — `addon_key`, a title, `revision`, and `Maker::AddonOrigin.link_for(state, addons:)`), `@generated_ids = @generated.keys.to_set`; `@addon_origins` stays for the tiles' menus.

- [ ] **Step 3: the views.** `_attachments.html.erb` keeps its head and actions and gains a `view-toggle` (Tiles / List, links with `view:` on `project_path`) in the head. Body, in order: **Loose** (root files; the sweep's inbox — shown only when any, with a one-line `p.muted` "Loose files are filed on the next sweep"); one **section per subfolder** via `_file_tree_section.html.erb` (`details open` — the `backups`-named folder closed — `summary` = the folder name + count; a repo section's summary adds a `.badge` "repo" and links to `repo_commit_path(dir.node_id)` and `repo_history_path(dir.node_id)`; nested subfolders render the same partial inside; files render as tiles (`_attachment_group`'s tile markup, extracted into `_file_tile.html.erb` if it is not already) or as rows of `_file_rows.html.erb` (`table.table.project-files`: Name link, Section (the subfolder path), Size (`node.size` via `number_to_human_size`), Modified, Origin (the tool, when generated)) depending on `@view`); **Generated** (`_generated_group.html.erb`: every file in `@generated`, listed once here and NOT repeated inside its section — filter `@generated_ids` out of the section files — showing the tool's title, the saved item's title and "rev N", and "Open in <tool>" from `link_for`); **Linked** (unchanged). Repositories as a separate group go away (a repo is a section now). The stats line keeps `@listing.total`. Backups: a file `Maker::FileAttachment.backup?` still goes to a closed Backups section rather than its folder section — keep S2-2's rule. `.ptr`: `Node.visible_entries(false)` additionally excludes `name LIKE '%.ptr'` (and the comment says why: pointer stubs from the git-tracking arc, never written now, junk in every listing); `pages/projects.css` in its layer: `.file-tree-section summary`, `.project-files` drops (`col-section`, `col-modified` at 719px; `col-size` at 479px).

- [ ] **Step 4: the sweep.** `lib/tasks/projects.rake` gains:

```ruby
  desc "Delete stray *.ptr pointer stubs beside their real file under Projects/ (DRY_RUN=1 reports only)"
  task sweep_pointers: :environment do
    # A POINTER WITHOUT ITS REAL FILE IS NOT TOUCHED — that is the git-tracking arc's own shape (the
    # pointer stands for a binary that is elsewhere), and deleting it would be data loss. Deletion goes
    # through the port so the stub lands in the trash, restorable, never the void.
    dry = ENV["DRY_RUN"] == "1"
    User.find_each do |user|
      tree = Maker::LibraryTree.new(user)
      user.nodes.present.where(kind: "file").where("name LIKE '%.ptr'").find_each do |ptr|
        next unless tree.path_for(ptr.parent_node_id).to_s.start_with?(Maker::ProjectFolders::ROOT)
        real = user.nodes.present.find_by(parent_node_id: ptr.parent_node_id, name: ptr.name.delete_suffix(".ptr"))
        next puts("keep   #{ptr.name} (no real file beside it)") unless real
        puts "#{dry ? 'would delete' : 'delete'} #{tree.path_for(ptr.parent_node_id)}/#{ptr.name}"
        FileLayer.current.delete(user, node_id: ptr.node_id) unless dry
      end
    end
  end
```

(Check `FileLayer.current.delete`'s exact signature in `app/services/file_layer/share.rb` and how `FilesController#destroy` calls it; on chunk_remote the same verb goes over the wire.) Test in `test/tasks/` (read a sibling for the idiom): with a fresh share library, a pointer beside its file is deleted (tombstoned, bytes in `.trash`) and one without is kept; `DRY_RUN=1` deletes nothing; a pointer outside `Projects/` is left alone.

- [ ] **Step 5: tests.** `project_attachments_test.rb` (rewrite the S2-2 grouping tests to the tree): a project folder with `models/bracket.stl`, `docs/manual.pdf`, `docs/wiring/pinout.pdf`, root `notes.txt` → `Loose` first with `notes.txt`; `details.file-tree-section` for `models` and `docs`; `docs` nests `wiring`; each summary carries its count; a repo subfolder renders `.badge` "repo" with links to its commit and history pages and its files inside; a `.ptr` beside `bracket.stl` renders nowhere on the page; the list view (`?view=list`) renders `table.table.project-files` rows with Section and Origin cells and the cookie remembers it; a generated file (create an `AddonState` + `AddonFile` for the node — read `test/` for the fixture idiom, e.g. `addon_origin_surfaces_test.rb`) appears in `.generated-group` with its tool, item and "rev N" and NOT in its section; Linked unchanged; the empty state. `project_page_test.rb`: the stats line and Detach unchanged. Budget (`projects#show`): the seed grows subfolders two deep, generated files and repos — constant.

- [ ] **Step 6: mutation-check** (stage first; verbatim; restore): (a) the walk stops at repos again → the repo-section test fails; (b) the `.ptr` rule dropped from `visible_entries` → the pointer test fails; (c) generated files not filtered out of their section → the "listed once" assertion fails; (d) `AddonOrigin.for` per row → the budget fails; (e) the sweep deleting a pointer with no real file → the keep test fails.

- [ ] **Step 7: commit** with a pathspec: `The project's folder as a tree: sections are subfolders, repositories open in place, tool output is Generated, a list view, pointers hidden and swept`.

---

### Task C: close-out (the orchestrator)

- [ ] Both landed; `settings_hub_test`'s row count; look at the panel in both views on the dev server; `bin/ci`; `/finish-branch`; `bin/log arc --from-pr <n>`; then run `rake projects:sweep_pointers` DRY on the share box and, if it reads right, for real, and record it.
