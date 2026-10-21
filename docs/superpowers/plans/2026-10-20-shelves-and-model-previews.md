# Shelves, model cards and chosen previews — implementation plan

> **For agentic workers:** execute with `.claude/commands/execute-plan.md` (CLAUDE.md §15 — it
> overrides any generic subagent loop). Steps use checkbox (`- [ ]`) syntax for tracking. The tasks
> below are ALREADY batched by file; do not split them further.

**Goal:** Replace the model-catalog Shelves setting with a fixed rule, turn the Filing settings into
first-class Shelves (add/remove, a default view each, groups), clean up model cards, and let a maker
pick a file's preview angle in the 3D viewer.

**Spec:** `docs/superpowers/specs/2026-10-20-shelves-and-model-previews-design.md` — read it first.

**Architecture:** Three independent parts on one branch. Shelves are a new `maker_shelves` table
(reusing the name the retired model shelves held) plus `maker_shelf_groups`; filing rules keep their
`folder` string and join by name. The project page learns a shelf's default view and group through
`ProjectFolderListing#panel_folders`, so all three layout callers pick it up. A viewer preview is a
`maker_previews` row with `source: "viewer"` that `Maker::Previews::Enqueue` treats as current while
its content token matches.

**Tech stack:** Rails 8, Hotwire/Stimulus, SQLite in test, Online3DViewer (vendored `o3dv.js`).

---

## Ground rules for every task

- Hand-run tests as `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test <files>`.
  Bare `bin/rails test` errors ~187 times for want of `LIBRARY_PATH`; that is environmental.
- Run Ruby that edits repo files with `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8` (the Bash tool's
  locale is US-ASCII).
- Parallel agents share one worktree: run ONLY your focused test files, `git add <your paths>`
  explicitly, and commit with a pathspec and a message file:
  `git commit -F <msgfile> -- <your paths>` (a backtick inside `-m "..."` runs as a command in zsh).
  End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Mutation-check every guard you write** (CLAUDE.md §15): break the guarded line, run the test,
  paste the actual red output into your report, restore with `git checkout -- <file>` (stage a NEW
  file before mutating it — `checkout` cannot restore an untracked file), then clear
  `tmp/cache/bootsnap*` before the green re-run.
- An ERB comment ends at its first `%>`: never quote ERB inside `<%# … %>`.
- `assert_select "[attr=?]", /regex/` never matches; use `:match('attr', ?)` or a String.
- Upload-control assertions on the Files/model pages must branch on `port_writable?`.
- When a change invalidates documented behaviour, grep every file that documents it and fix all of
  them in the same task.

## Waves

| wave | tasks (parallel within a wave) | why this order |
|---|---|---|
| 1 | Task 1, Task 2, Task 3 | disjoint files; Task 3 owns the only migration in this wave |
| 2 | Task 4 | its migration drops the table Task 2 stops reading; it must follow Tasks 2 and 3's schema |
| 3 | Task 5, Task 6 | both need Task 4's / Task 3's models; disjoint files |
| 4 | Task 7 (orchestrator) | docs, full `bin/ci`, PR, record |

---

### Task 1: Model cards — no status badge, square preview

**Files:**
- Modify: `app/views/models/_card.html.erb`
- Modify: `app/assets/stylesheets/pages/models.css` (the two `.model-card` rules at ~line 70)
- Modify: `test/integration/web/models_pages_test.rb` (the test at ~line 45)
- Modify: `test/system/projects_models_pages_test.rb` (add one test)

- [ ] **Step 1: Rewrite the request test** at `models_pages_test.rb:45` ("a model card keeps its
  badge, which the stylesheet places over the cover") and fix the file's header comment (line 5
  says "the status badge over the cover"):

```ruby
    # NO STATUS BADGE ON THE CARD (2026-10-20, the owner's call): it covered the corner of the
    # picture, and the status is one click away -- the chips above the grid filter by it and the
    # model's own page shows it.
    test "a model card carries no status badge" do
      # (keep this test's existing setup lines that create a `printed` model and GET the page)
      assert_select ".model-card", minimum: 1
      assert_select ".model-card .badge", count: 0
    end
```

- [ ] **Step 2: Add a system test** to `test/system/projects_models_pages_test.rb`, following that
  file's own setup for a model with a cover (read it first; reuse its helpers):

```ruby
  # SQUARE, MEASURED IN A BROWSER: a stylesheet rule cannot be asserted from a request test.
  test "a model card's preview box is square" do
    # (set up one catalogued model with a cover node the way this file's other tests do)
    visit files_models_path
    w, h = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector(".model-card .thumb").getBoundingClientRect();
               return [Math.round(r.width), Math.round(r.height)] })()
    JS
    assert_operator w, :>, 120, "the column should be wider than the old fixed 120px height"
    assert_equal w, h
  end
```

- [ ] **Step 3: Run both; expect the badge test and the square test RED.**

- [ ] **Step 4: Implement.** In `_card.html.erb` delete the line
  `<span class="badge mstatus-<%= model.print_status %>"><%= model.print_status_label %></span>`.
  In `pages/models.css` replace the badge comment and its two rules with:

```css
  /* A MODEL'S COVER IS SQUARE (2026-10-20). `.project-card .thumb` is a fixed 120px tall in a grid
     whose columns are at least 150px wide, so a square render sat in a short, wide box. Model cards
     only: project and explore cards keep their banner shape. The status badge that sat over the
     cover's corner is gone; the chips above the grid and the model page carry the status. */
  .model-card .thumb { height: auto; aspect-ratio: 1 / 1; }
```

  Check `mstatus-*` rules are still used elsewhere (`grep -rn "mstatus-" app/`) — the model page
  still renders a badge; leave those rules.

- [ ] **Step 5: Green, then mutation-check:** remove the `aspect-ratio` line → the system test goes
  red; restore. Run `test/css_hygiene_test.rb` and `test/integration/web/template_hygiene_test.rb`.

- [ ] **Step 6: Commit** (`app/views/models/_card.html.erb app/assets/stylesheets/pages/models.css
  test/integration/web/models_pages_test.rb test/system/projects_models_pages_test.rb`), message
  "Model cards: no status badge, a square preview".

---

### Task 2: Which folders are 3D models becomes a built-in rule

Owns `app/services/maker/model_intake.rb` and the model-intake tests and docs. **Does NOT touch**
`app/models/maker/shelf.rb`, the `maker_shelves` table, `Settings::ShelvesController` or any
settings view — Task 4 replaces those.

**Files:**
- Modify: `app/services/maker/model_intake.rb` (lines ~84, ~210-285)
- Modify: `test/services/maker/model_intake_classify_test.rb`
- Modify: `test/services/maker/model_intake_test.rb` (line ~13 setup; test at ~281)
- Modify: `test/services/maker/model_intake_prune_test.rb` (line ~23)
- Modify (comments only): `test/jobs/maker/model_intake_job_test.rb:34-36`,
  `test/jobs/library/scan_job_test.rb:~513`
- Modify: `docs/invariants/model-intake.md`, `CLAUDE.md` (§14k stub only)

- [ ] **Step 1: Tests first** in `model_intake_classify_test.rb`:
  - delete `@user.maker_shelves.create!(path: "3D Models")` from `setup`;
  - replace `def classify = Maker::ModelIntake.classify(@user)` with
    `def classify(patterns = [ "3D Models" ]) = Maker::ModelIntake.classify(@user, patterns:)`;
  - nested test ("a shelf inside a model folder takes over its children"): drop the `create!`,
    call `classify([ "3D Models", "3D Models/Enclosure" ])`;
  - wildcard test: drop the `create!`, call `classify([ "3D Models", "Projects/*/models" ])`;
  - add, at the end of the class:

```ruby
    # THE BUILT-IN SHELVES (2026-10-20). Until then these four were per-user rows edited at
    # /settings/shelves; every live user held exactly these four when the page was retired.
    test "the built-in shelves are the four that shipped" do
      assert_equal [ "", "*", "Models", "Projects/*/models" ], Maker::ModelIntake::SHELVES
    end

    test "with no patterns given, the built-in shelves decide" do
      file("f-rootfile", "loose.stl", nil)
      plan = Maker::ModelIntake.classify(@user)
      assert_includes plan.model_keys, "f-rootfile", "the library root is a built-in shelf"
      assert_includes plan.model_keys, "f-benchy", "every top-level folder is a built-in shelf"
    end

    # The matcher moved here from Maker::Shelf.matches? with its rules unchanged.
    test "a wildcard segment matches exactly one segment" do
      m = ->(p, x) { Maker::ModelIntake.shelf_matches?(p, x) }
      assert m.call("", "")
      assert_not m.call("*", "")
      assert m.call("*", "Models")
      assert_not m.call("*", "a/b")
      assert m.call("Projects/*/models", "Projects/lamp/models")
      assert_not m.call("Projects/*/models", "Projects/lamp/x/models")
    end
```

  In `model_intake_test.rb` delete the setup `create!(path: "3D Models")` (the built-in `*`
  covers it). Rewrite the "a folder matched by two shelves is catalogued once" test so that its
  folder sits under a top-level `Models/` dir (which both `*` and `Models` name) — build the dir
  rows the way that file's setup does — and assert one `maker_models` row for it. In
  `model_intake_prune_test.rb:23` delete the `create!`. Fix the two test comments that cite
  `Maker::Shelf::SEEDS` / `seed_once!` to cite `Maker::ModelIntake::SHELVES`.

- [ ] **Step 2: Run** the three service test files and `model_intake_job_test.rb`; expect
  `NoMethodError`/`ArgumentError` on `patterns:`/`SHELVES`/`shelf_matches?`.

- [ ] **Step 3: Implement** in `model_intake.rb`:
  - delete `Maker::Shelf.seed_once!(user)` from `for_user`;
  - add near the other constants:

```ruby
    # THE SHELVES ARE BUILT IN (2026-10-20). A shelf is a folder that is not itself a model: a
    # model-role file directly on one is its own model, and each of its subfolders is one model.
    # These four were per-user `maker_shelves` rows edited at /settings/shelves until that page was
    # retired; every live user held exactly these four when it went, so fixing them changed no
    # one's catalog, and `maker_shelves` now means something else (Maker::Shelf).
    #
    # `*` -- EVERY TOP-LEVEL FOLDER IS A SHELF -- IS THE ONE THAT IS EASY TO READ AS REDUNDANT NEXT
    # TO `""`, AND REMOVING IT BREAKS THE HEADLINE CASE. `""` alone makes each top-level folder ONE
    # model holding its whole subtree: measured on a real share library, `3D Models/` collapsed into
    # a single entry and `Projects/` became one entry. `Projects/*/models` is still needed beside
    # it: `*` makes `Projects` a shelf, and the deeper pattern is the NEARER shelf inside `models/`.
    SHELVES = [ "", "*", "Models", "Projects/*/models" ].freeze
    # A whole segment may be this and nothing else.
    WILDCARD = "*".freeze

    # Does `pattern` name `path`? Both are "" for the library root, segments joined by "/".
    # A "*" segment matches exactly one segment -- never zero, never several.
    def self.shelf_matches?(pattern, path)
      ps = pattern.to_s.split("/")
      xs = path.to_s.split("/")
      return false unless ps.size == xs.size

      ps.zip(xs).all? { |p, x| p == WILDCARD || p == x }
    end
```

  - `classify(user)` becomes `classify(user, patterns: SHELVES)`, its `patterns =
    user.maker_shelves.pluck(:path)` line goes, and its header comment says it reads `nodes` only;
  - in `shelf_dir_ids`, both `Maker::Shelf.matches?` calls become `shelf_matches?`.

- [ ] **Step 4: Green.** Mutation-check: change `SHELVES` to drop `""` → "with no patterns given"
  goes red; change `classify`'s default to `[]` → same; restore.

- [ ] **Step 5: Docs.** In `docs/invariants/model-intake.md`: drop `app/models/maker/shelf.rb` and
  `app/controllers/settings/shelves_controller.rb` from the header's path list; rewrite the bullet
  "A SHELF IS A PATH PATTERN AND A MODEL IS A NODE ID" to say the patterns are now
  `Maker::ModelIntake::SHELVES`, fixed in code, and that the cost of a path-keyed shelf (renaming
  `Models/` stops it matching) is now visible only as models disappearing; delete the three
  bullets "THE WILDCARD CLAUSE IN `Shelf`'S PATH VALIDATION…", "`Shelf.seed_once!` USES
  `find_or_create_by!`…" and "SEEDING HAPPENS ONCE…" (the code they guard is gone — say so in one
  line where the first one was, with the date). Keep every other bullet. In `CLAUDE.md` §14k's stub
  remove `shelf` from `app/models/maker/{model,item,shelf}.rb` and remove
  `app/controllers/settings/shelves_controller.rb`; leave the rest of the stub. Run
  `test/docs_hygiene_test.rb`.

- [ ] **Step 6: Commit** the files above, message "Which folders are 3D models is a built-in rule".

---

### Task 3: A preview can come from the viewer (data layer)

**Files:**
- Create: `db/migrate/20261020190000_add_source_to_maker_previews.rb`
- Modify: `db/schema.rb` (via `bin/rails db:migrate`), `app/models/maker/preview.rb`,
  `app/services/maker/previews/enqueue.rb`, `app/jobs/maker/generate_preview_job.rb`
- Test: the existing `test/services/maker/previews/enqueue_test.rb` and
  `test/jobs/maker/generate_preview_job_test.rb` (find them with `ls test/services/maker/previews
  test/jobs/maker`; add to them, following their setup)

- [ ] **Step 1: Migration** (copy the `ActiveRecord::Migration[x.y]` version from the newest file in
  `db/migrate/`):

```ruby
# A PREVIEW THE MAKER CHOSE (2026-10-20): "Use this view as preview" in the 3D viewer writes the
# thumbnail row with source "viewer", and Maker::Previews::Enqueue leaves such a row alone for as
# long as its content token matches the file's.
class AddSourceToMakerPreviews < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_previews, :source, :string, null: false, default: "renderer"
  end
end
```

  Run `bin/rails db:migrate` and `LIBRARY_PATH=$(mktemp -d) bin/rails schema:map` if
  `test/schema_map_test.rb` asks for it (it lists columns per table).

- [ ] **Step 2: Failing tests.** In the Enqueue test file add (adapt the fixture to how that file
  builds a user, a node and a `ready` thumbnail row with an attached asset):

```ruby
  # A VIEWER PREVIEW IS CURRENT WHILE ITS CONTENT IS (2026-10-20): a renderer upgrade must not
  # repaint the angle the maker chose.
  test "a viewer preview survives a renderer revision bump" do
    row = ready_thumbnail!(source: "viewer", renderer_revision: 0) # 0: older than any real revision
    assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
      Maker::Previews::Enqueue.call(user: @user, node_id: row.node_id, name: "part.stl",
                                    version_id: row.version_id)
    end
    row.reload
    assert_equal [ "viewer", "ready" ], [ row.source, row.status ]
  end

  test "a viewer preview of old content goes back to the renderer" do
    row = ready_thumbnail!(source: "viewer")
    assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
      Maker::Previews::Enqueue.call(user: @user, node_id: row.node_id, name: "part.stl",
                                    version_id: "new-content")
    end
    row.reload
    assert_equal [ "renderer", "pending", "new-content" ], [ row.source, row.status, row.version_id ]
  end

  test "a viewer preview is current whatever its renderer revision" do
    row = ready_thumbnail!(source: "viewer", renderer_revision: 0)
    assert_equal row, Maker::Previews::Enqueue.current_preview(user: @user, node_id: row.node_id,
                                                                name: "part.stl", version_id: row.version_id,
                                                                kind: "thumbnail")
    assert Maker::Previews::Enqueue.current_preview?(row, name: "part.stl", version_id: row.version_id)
  end
```

  In the job test add: a `viewer` row with an attached asset, `perform_now` the job for it, and
  assert the row is still `viewer`/`ready` and `row.asset.blob.id` is unchanged (a render queued
  before the click must not land on top of it). Add a model test that `source` refuses `"other"`.

- [ ] **Step 3: Run; expect red** (unknown attribute `source`, then the behaviour assertions).

- [ ] **Step 4: Implement.**

  `app/models/maker/preview.rb`, beside `STATUSES`:

```ruby
    # WHO MADE THE PICTURE (2026-10-20). `renderer` is the server-side render every row starts
    # as; `viewer` is a PNG the maker took in the 3D viewer ("Use this view as preview",
    # Files::PreviewsController). Maker::Previews::Enqueue treats a viewer row whose content token
    # still matches as current whatever the renderer revision, and GeneratePreviewJob never writes
    # over one; a content change repoints the row and hands it back to the renderer.
    SOURCES = %w[renderer viewer].freeze
```

  with `validates :source, inclusion: { in: SOURCES }` and `def viewer? = source == "viewer"`.

  `enqueue.rb` — in `call`, right after `content_moved = …`:

```ruby
        # A viewer preview of content that has moved on is a picture of geometry that no longer
        # exists, so the row goes back to the renderer with the content.
        preview.source = "renderer" if content_moved
```

  `needs_job?` becomes:

```ruby
      def needs_job?(preview, version_id:, revision:, retry_failed:)
        return true if preview.nil? || preview.new_record?
        return true if preview.version_id != version_id
        # THE MAKER'S CHOICE OUTRANKS A RENDERER UPGRADE (2026-10-20): same content, so no job.
        return false if preview.viewer?
        return true if preview.renderer_revision != revision
        return retry_failed if preview.failed?

        stalled?(preview)
      end
```

  `current_preview` and `current_preview?`:

```ruby
      def current_preview(user:, node_id:, name:, version_id:, kind:)
        return nil if name.blank? || version_id.blank?

        row = user.maker_previews.find_by(node_id:, kind:, version_id:)
        row if row && revision_current?(row, name)
      end

      def current_preview?(preview, name:, version_id:)
        return false if name.blank? || version_id.blank?

        preview.version_id == version_id && revision_current?(preview, name)
      end

      # A viewer row is current at ANY renderer revision; a rendered one only at this build's.
      def revision_current?(preview, name)
        preview.viewer? || preview.renderer_revision == revision_for_name(name, preview.kind)
      end
```

  Keep (and adjust, don't delete) the existing comments above each method; mention the viewer
  exception in one sentence each. `generate_preview_job.rb#commit_if_current`, after `reload`:

```ruby
      # NEVER OVER A PICTURE THE MAKER CHOSE (2026-10-20): a render queued before they clicked
      # "Use this view as preview" finds the row turned `viewer` and stands down.
      return false if preview.viewer?
```

- [ ] **Step 5: Green**, plus `test/services/maker/previews/` and `test/jobs/maker/` whole dirs and
  `test/services/maker/previews/missing_backfill_test.rb` (it reads `current_preview?`).
  Mutation-check each of the four guards (the `needs_job?` line, the `source = "renderer"` reset,
  `revision_current?`'s `viewer? ||`, the job's `return false`) — each must turn one named test red.

- [ ] **Step 6: Commit** the migration, `db/schema.rb`, any schema-map output, the three app files
  and the tests; message "A preview can come from the 3D viewer: the data layer".

---

### Task 4: Shelves — the data and the settings page

One implementer, sequential commits allowed. It replaces the old `maker_shelves` model wholesale
and moves the Filing page to `/settings/shelves`.

**Files:**
- Create: `db/migrate/20261020190100_replace_model_shelves_with_filing_shelves.rb`
- Rewrite: `app/models/maker/shelf.rb`; Create: `app/models/maker/shelf_group.rb`,
  `app/services/maker/shelves.rb`
- Modify: `app/models/user.rb` (line ~97), `app/models/maker/filing_rule.rb`
- Rewrite: `app/controllers/settings/shelves_controller.rb`; Create:
  `app/controllers/settings/shelf_groups_controller.rb`; Modify:
  `app/controllers/settings/filing_rules_controller.rb`, `app/controllers/settings_controller.rb`
- Rewrite: `app/views/settings/shelves/index.html.erb`; Create:
  `app/views/settings/shelves/_shelf_card.html.erb`; Delete:
  `app/views/settings/filing_rules/index.html.erb`, `app/views/settings/filing_rules/_folder_card.html.erb`
- Modify: `config/routes.rb` (the settings namespace, ~line 425-437),
  `app/views/settings/show.html.erb`, `app/views/files/models/index.html.erb` (drop the hint),
  `app/assets/stylesheets/pages/models.css` (drop `.shelf-*` and `.models-shelves-hint` rules),
  `app/assets/stylesheets/pages/settings.css`, `app/views/help/show.html.erb`,
  `app/views/shared/_where_files_come_from.html.erb`, `app/helpers/shell_helper.rb` (comments),
  `app/services/maker/filing_rules.rb` (comments), `lib/schema_map.rb` + its generated output
- Tests: `git mv test/integration/web/settings_filing_test.rb test/integration/web/settings_shelves_test.rb`;
  delete `test/integration/web/shelves_test.rb`; rewrite `test/models/maker/shelf_test.rb`; create
  `test/models/maker/shelf_group_test.rb`, `test/services/maker/shelves_test.rb`; modify
  `settings_hub_test.rb`, `page_query_budget_test.rb`, `help_page_test.rb`,
  `moved_reference_pages_test.rb`, `models_redirects_test.rb` (~line 88),
  `template_hygiene_test.rb`, `test/models/tenant_cleanup_test.rb`,
  `test/models/structural_orphan_test.rb`, `test/models/maker/filing_rule_test.rb` (comment)

- [ ] **Step 1: Migration.** No backfill — rows are derived on read (Step 3).

```ruby
# THE SHELVES ARE THE FILING FOLDERS (2026-10-20). `maker_shelves` held the model catalog's path
# patterns; those became Maker::ModelIntake::SHELVES, fixed in code, after every live user was
# measured holding exactly the four seeds. The name now belongs to the folders the intake sweep
# files into inside each project, each with a default view and an optional group. Rows are made
# on read by Maker::Shelves.ensure!, so nothing is backfilled here.
class ReplaceModelShelvesWithFilingShelves < ActiveRecord::Migration[8.1]
  def up
    drop_table :maker_shelves
    remove_column :users, :shelves_seeded_at

    create_table :maker_shelf_groups do |t|
      t.integer :user_id, null: false
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_shelf_groups, %i[user_id name], unique: true

    create_table :maker_shelves do |t|
      t.integer :user_id, null: false
      t.string :name, null: false
      t.string :default_view
      t.integer :shelf_group_id
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_shelves, %i[user_id name], unique: true
    add_index :maker_shelves, :shelf_group_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

  Run `bin/rails db:migrate`.

- [ ] **Step 2: Models.** `app/models/maker/filing_rule.rb`: extract the folder check into a class
  method both models call (same three questions, one spelling):

```ruby
    # ONE PATH SEGMENT THE LIBRARY WILL ACCEPT AS A FOLDER NAME. Shared with Maker::Shelf, whose
    # name IS the folder these rules file into, so the two can never disagree about what a valid
    # folder is.
    def self.plain_segment?(name)
      Maker::MoveNode.valid_leaf_name?(name) && !name.include?("/") &&
        !Library::ReservedNames.reserved?(name)
    end
```

  and `folder_is_a_plain_segment` uses it (`ok = self.class.plain_segment?(folder)`); its comment
  stops citing `Maker::Shelf#path_segments_are_allowed` and cites `Maker::Shelf` instead.

  `app/models/maker/shelf.rb` (replace the whole file):

```ruby
module Maker
  # A SHELF IS A FOLDER INSIDE EVERY PROJECT (2026-10-20): `Projects/<project>/<name>/`, where the
  # intake sweep files whatever Maker::FilingRule rows name it. Its `name` IS that folder name and
  # joins the rules by string, so the sweep (Maker::ProjectFolders.folder_for) did not change.
  # `default_view` is how the folder's panel opens on a project page (nil = automatic), and a
  # group puts its shelves' panels under one heading there. Rows are made on read by
  # Maker::Shelves.ensure!. NOT the model catalog's shelves: those are Maker::ModelIntake::SHELVES.
  class Shelf < ApplicationRecord
    self.table_name = "maker_shelves"

    belongs_to :user
    belongs_to :shelf_group, class_name: "Maker::ShelfGroup", optional: true

    normalizes :name, with: ->(n) { n.to_s.strip.downcase }
    normalizes :default_view, with: ->(v) { v.presence }

    validates :name, presence: true, uniqueness: { scope: :user_id }
    validates :default_view, inclusion: { in: Maker::Project::VIEWS }, allow_nil: true
    validate :name_is_a_folder_name
    # GUARDED ON PRESENCE, AND SAFE ONLY BECAUSE ShelfGroup NULLIFIES (§14d): a dangling id would
    # be present and lock every later edit of this row.
    validate :group_is_this_users, if: -> { shelf_group_id.present? }

    # `other` is where an extension with no shelf files, so it cannot be removed.
    def fallback? = name == Maker::Shelves::FALLBACK

    private

    def name_is_a_folder_name
      return if name.blank?
      return if Maker::FilingRule.plain_segment?(name)

      errors.add(:name, "isn't allowed - #{name.inspect} can't be a folder name")
    end

    def group_is_this_users
      return if user && user.maker_shelf_groups.exists?(id: shelf_group_id)

      errors.add(:shelf_group_id, "isn't one of your groups")
    end
  end
end
```

  `app/models/maker/shelf_group.rb`:

```ruby
module Maker
  # A NAMED SET OF SHELVES (2026-10-20). Display only: a project page draws one heading over the
  # panels of a group's folders, and the folders on disk stay flat. Deleting a group leaves its
  # shelves ungrouped (`nullify`), never deleted.
  class ShelfGroup < ApplicationRecord
    self.table_name = "maker_shelf_groups"
    NAME_MAX = 40

    belongs_to :user
    has_many :shelves, class_name: "Maker::Shelf", foreign_key: :shelf_group_id,
                       inverse_of: :shelf_group, dependent: :nullify

    normalizes :name, with: ->(n) { n.to_s.squish }

    validates :name, presence: true, length: { maximum: NAME_MAX }, uniqueness: { scope: :user_id }
  end
end
```

  `app/models/user.rb:97`: keep `has_many :maker_shelves, class_name: "Maker::Shelf",
  dependent: :destroy` and add below it
  `has_many :maker_shelf_groups, class_name: "Maker::ShelfGroup", dependent: :destroy`.

  `app/services/maker/shelves.rb`:

```ruby
module Maker
  # ONE USER'S SHELVES (2026-10-20). Two reads, and only the settings page's may write.
  module Shelves
    # Where an extension with no rule files (Maker::ProjectFolders.folder_for). No seeded rule
    # names it -- no extension carries the `other` role -- so it is added here by name.
    FALLBACK = "other".freeze

    # What a project page needs to know about one folder name.
    Entry = Data.define(:view, :group, :group_position)

    module_function

    # THE SETTINGS PAGE'S READ: a shelf row for every folder a filing rule names, plus `other`,
    # made on the way in. That is what keeps shelves and rules from drifting apart -- a rule moved
    # to a new folder by FilingRulesController#update, or written by an older version of this app,
    # simply gains its shelf here -- and it is why there is no second seed list: the filing rules'
    # own seed (Maker::FilingRules.seed!) is the seed. Positions follow the seed's folder order so a
    # new user's page reads in the order it always has; a custom folder lands after.
    def ensure!(user)
      Maker::FilingRules.seed!(user)
      wanted = (user.maker_filing_rules.distinct.pluck(:folder) + [ FALLBACK ]).uniq
      missing = wanted - user.maker_shelves.pluck(:name)
      return if missing.empty?

      seed_order = Maker::ProjectFolders::ROLE_FOLDERS.values.uniq
      start = (user.maker_shelves.maximum(:position) || -1) + 1
      now = Time.current
      rows = missing.sort_by { |n| [ seed_order.index(n) || seed_order.size, n ] }
                    .each_with_index.map do |name, i|
        { user_id: user.id, name:, position: start + i, created_at: now, updated_at: now }
      end
      # ON CONFLICT DO NOTHING: two first visits at once both land the same names.
      Maker::Shelf.insert_all(rows)
    end

    # THE PROJECT PAGE'S READ: folder name => Entry, ONE query, and NO write -- a GET of a project
    # must not mint rows. A folder with no shelf row is simply automatic.
    def by_name(user)
      user.maker_shelves.left_joins(:shelf_group)
          .pluck("maker_shelves.name", "maker_shelves.default_view",
                 "maker_shelf_groups.name", "maker_shelf_groups.position")
          .to_h { |name, view, group, pos| [ name, Entry.new(view:, group:, group_position: pos) ] }
    end
  end
end
```

- [ ] **Step 3: Model and service tests** (write first, watch red, then make green):
  - `test/models/maker/shelf_test.rb` (replace): name normalised (`" Laser "` → `"laser"`); a
    reserved name (`.trash`), a slash (`a/b`) and a blank refused; duplicate per user refused, same
    name for another user allowed; `default_view` accepts each of `Maker::Project::VIEWS` and `""`
    (stored nil), refuses `"grid"`; another user's group refused with "isn't one of your groups";
    `fallback?` true only for `other`.
  - `test/models/maker/shelf_group_test.rb`: name squished, blank refused, 41 chars refused,
    duplicate per user refused; destroying a group nullifies its shelves' `shelf_group_id` and keeps
    the shelves.
  - `test/services/maker/shelves_test.rb`:

```ruby
require "test_helper"

module Maker
  class ShelvesTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "shv-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    # ROLE_FOLDERS.values.uniq is the seed's folder order and ends in `other` (measured
    # 2026-10-20: cnc laser design models cad code docs images archives pcb other).
    test "a new user gets one shelf per seeded folder, in the seed's order" do
      Maker::Shelves.ensure!(@user)
      assert_equal Maker::ProjectFolders::ROLE_FOLDERS.values.uniq,
                   @user.maker_shelves.order(:position).pluck(:name)
    end

    test "other gets a shelf though no rule names it" do
      Maker::FilingRules.seed!(@user)
      assert_not @user.maker_filing_rules.exists?(folder: "other")
      Maker::Shelves.ensure!(@user)
      assert @user.maker_shelves.exists?(name: "other")
    end

    test "a folder a rule names gains a shelf, after the seeded ones" do
      Maker::Shelves.ensure!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")
      Maker::Shelves.ensure!(@user)
      last = @user.maker_shelves.order(:position).last
      assert_equal "prints", last.name
    end

    test "ensure! is idempotent" do
      Maker::Shelves.ensure!(@user)
      assert_no_difference -> { @user.maker_shelves.count } do
        Maker::Shelves.ensure!(@user)
      end
    end

    test "by_name answers view and group per folder name and writes nothing" do
      group = @user.maker_shelf_groups.create!(name: "Fabrication", position: 2)
      @user.maker_shelves.create!(name: "laser", default_view: "list", shelf_group: group)
      @user.maker_shelves.create!(name: "docs")
      map = assert_no_difference(-> { @user.maker_shelves.count }) { Maker::Shelves.by_name(@user) }
      assert_equal Maker::Shelves::Entry.new(view: "list", group: "Fabrication", group_position: 2), map["laser"]
      assert_equal Maker::Shelves::Entry.new(view: nil, group: nil, group_position: nil), map["docs"]
    end
  end
end
```

  Mutation-check: drop `+ [ FALLBACK ]` → "other gets a shelf" red; drop `dependent: :nullify` →
  the group-destroy test red; drop `group_is_this_users` → the foreign-group test red.

- [ ] **Step 4: Guards for the new tables.** Run these four now, not at the full gate:
  - `lib/schema_map.rb`: in the "Models & projects" table list add `maker_shelf_groups` after
    `maker_shelves`; in `EDGES` add
    `[ "maker_shelves.shelf_group_id", "maker_shelf_groups.id", "app", "in group" ],` beside the
    other maker `.id` edges; delete the comment "maker_shelves DELIBERATELY HAS NO EDGE HERE…".
    Regenerate with `LIBRARY_PATH=$(mktemp -d) bin/rails schema:map`. Run `test/schema_map_test.rb`.
  - `test/models/tenant_cleanup_test.rb`: builders
    `"maker_shelf_groups" => ->(u) { u.maker_shelf_groups.create!(name: "Fabrication") },` and
    `"maker_shelves" => ->(u) { u.maker_shelves.create!(name: "renders") },`; in `BUILD_ORDER` put
    `maker_shelf_groups` immediately before `maker_shelves`.
  - `test/models/structural_orphan_test.rb` `CASES`:

```ruby
    "maker_shelves.shelf_group_id" => ->(u) {
      g = u.maker_shelf_groups.create!(name: "Fabrication")
      [ g, u.maker_shelves.create!(name: "laser", shelf_group: g) ]
    },
```

  - `test/integration/web/template_hygiene_test.rb`: the `"shelves" => settings_shelves_path` page
    stays; make sure the user that sweep signs in has one shelf group holding one shelf and one
    empty group, so both branches of the group section and the card partial render (read how
    that test seeds data and add it there).

- [ ] **Step 5: Routes.** In the `namespace :settings` block replace the shelves comment+line and
  the filing_rules line with:

```ruby
    # THE SHELVES (2026-10-20): the folders the intake sweep files into inside each project, one
    # card each with its extensions, its default view and its group. This page WAS Filing
    # (/settings/filing, which now redirects here); the model catalog's old shelves page that held
    # this path became Maker::ModelIntake::SHELVES, fixed in code. /models/shelves still lands here.
    resources :shelves, only: %i[index create update destroy]
    resources :shelf_groups, only: %i[create update destroy], path: "shelf-groups"
    get "filing", to: redirect("/settings/shelves")
    # The extension chips' own doors (stage 3, S3-1; stage 4, S4-2) under their old path. No index:
    # the page is Shelves. `update` stays routed with no control on the page (its tests drive it).
    resources :filing_rules, only: %i[create update destroy], path: "filing"
```

  Update the routes.rb comments near `get "models/shelves"` that describe the old page (it still
  redirects to `/settings/shelves`, which is now the Shelves page — say that in one line).

- [ ] **Step 6: Controllers.**

  `app/controllers/settings/shelves_controller.rb` (replace the whole file):

```ruby
module Settings
  # THE SHELVES (2026-10-20): one card per folder the intake sweep files into under
  # Projects/<project>/ -- its extensions, its default view on a project page, its group. This was
  # the Filing page (Settings::FilingRulesController#index) and kept its markup classes; the
  # extension chips still post to FilingRulesController. Session-authed (§14d); reads and writes
  # only maker_shelves, maker_shelf_groups and maker_filing_rules -- no port, nothing to gate.
  class ShelvesController < ApplicationController
    def index
      Maker::Shelves.ensure!(current_user)
      @groups = current_user.maker_shelf_groups.order(:position, :name).to_a
      shelves = current_user.maker_shelves.order(:position, :name).to_a
      @ungrouped = shelves.reject(&:shelf_group_id)
      @by_group = shelves.select(&:shelf_group_id).group_by(&:shelf_group_id)
      # ONE QUERY, GROUPED IN MEMORY -- a `where(folder:)` per card is a query per shelf
      # (page_query_budget_test.rb grows shelves to prove it does not).
      @by_folder = current_user.maker_filing_rules.order(:ext).to_a.group_by(&:folder)
    end

    def create
      shelf = current_user.maker_shelves.new(name: params.require(:shelf).permit(:name)[:name],
                                             position: next_position)
      if shelf.save
        redirect_to settings_shelves_path, notice: "Shelf #{shelf.name}/ added."
      else
        redirect_to settings_shelves_path, alert: shelf.errors.full_messages.to_sentence
      end
    end

    # The view and the group. NOT the name: a shelf's name is a folder inside every project on
    # disk, so renaming one would mean moving folders, which this page does not do.
    def update
      shelf = current_user.maker_shelves.find(params[:id])
      if shelf.update(params.require(:shelf).permit(:default_view, :shelf_group_id))
        redirect_to settings_shelves_path, notice: "Shelf #{shelf.name}/ updated."
      else
        redirect_to settings_shelves_path, alert: shelf.errors.full_messages.to_sentence
      end
    end

    # THE RULES GO WITH THE SHELF, in one transaction: a rule naming a folder with no shelf would
    # recreate the shelf on the next visit (Maker::Shelves.ensure!). Its extensions then file into
    # `other`, which is why `other` itself cannot go.
    def destroy
      shelf = current_user.maker_shelves.find(params[:id])
      if shelf.fallback?
        return redirect_to settings_shelves_path,
                           alert: "#{shelf.name}/ is where files with no shelf go, so it can't be removed."
      end

      Maker::Shelf.transaction do
        current_user.maker_filing_rules.where(folder: shelf.name).delete_all
        shelf.destroy!
      end
      redirect_to settings_shelves_path,
                  notice: "Shelf #{shelf.name}/ removed. Its extensions file into other now."
    end

    private

    def next_position = (current_user.maker_shelves.maximum(:position) || -1) + 1
  end
end
```

  `app/controllers/settings/shelf_groups_controller.rb`:

```ruby
module Settings
  # Shelf groups (2026-10-20): a heading on a project page over the panels of its shelves'
  # folders. Create, rename, delete; deleting leaves the shelves ungrouped (Maker::ShelfGroup).
  class ShelfGroupsController < ApplicationController
    def create
      group = current_user.maker_shelf_groups.new(name: group_name, position: next_position)
      if group.save
        redirect_to settings_shelves_path, notice: "Group #{group.name} added."
      else
        redirect_to settings_shelves_path, alert: group.errors.full_messages.to_sentence
      end
    end

    def update
      group = current_user.maker_shelf_groups.find(params[:id])
      if group.update(name: group_name)
        redirect_to settings_shelves_path, notice: "Group renamed to #{group.name}."
      else
        redirect_to settings_shelves_path, alert: group.errors.full_messages.to_sentence
      end
    end

    def destroy
      group = current_user.maker_shelf_groups.find(params[:id])
      group.destroy!
      redirect_to settings_shelves_path, notice: "Group #{group.name} removed. Its shelves are ungrouped."
    end

    private

    def group_name = params.require(:shelf_group).permit(:name)[:name]
    def next_position = (current_user.maker_shelf_groups.maximum(:position) || -1) + 1
  end
end
```

  `Settings::FilingRulesController`: delete `index` and its comments; every
  `redirect_to settings_filing_rules_path` becomes `redirect_to settings_shelves_path`; the class
  comment says the page is Shelves now (one sentence) and keeps the rest.
  `SettingsController#show`: drop `@filing_rule_count`; `@shelf_count` stays as it is.

- [ ] **Step 7: Views.** `app/views/settings/shelves/_shelf_card.html.erb` — start from
  `settings/filing_rules/_folder_card.html.erb` (keep its chip list, its add-extension form and
  every class it uses — the tests pin `.filing-card`, `.filing-folder`, `.filing-chip`,
  `.filing-add`), with these changes: locals become `shelf`, `by_folder`, `groups`; the heading reads
  `shelf.name`; rules come from `by_folder[shelf.name]`; the hidden `filing_rule[folder]` is
  `shelf.name`; and add a head row and a settings form:

```erb
<section class="filing-card shelf-card">
  <div class="shelf-card-head">
    <h2 class="filing-folder mono"><%= shelf.name %>/</h2>
    <% unless shelf.fallback? %>
      <%= button_to "Remove shelf", settings_shelf_path(shelf), method: :delete,
                    class: "linkbtn danger small",
                    form: { data: { turbo_confirm: "Remove the #{shelf.name}/ shelf? " \
                                                    "Its extensions will file into other." } } %>
    <% end %>
  </div>
  <%# (the chip list and the add-extension form from _folder_card, unchanged but for the folder) %>
  <%= form_with model: shelf, url: settings_shelf_path(shelf), scope: :shelf, method: :patch,
                class: "shelf-settings" do |f| %>
    <label>
      <span>View</span>
      <%= f.select :default_view,
                   [ [ "Automatic", "" ], *Maker::Project::VIEWS.map { |v| [ v.capitalize, v ] } ],
                   {}, id: nil %>
    </label>
    <label>
      <span>Group</span>
      <%= f.select :shelf_group_id, [ [ "None", "" ], *groups.map { |g| [ g.name, g.id ] } ],
                   {}, id: nil %>
    </label>
    <%= f.submit "Save", class: "btn ghost small" %>
  <% end %>
</section>
```

  Its header comment says what a shelf is, that `id: nil` is there because there is one form per
  card (keep the old comment's argument), and that `scope: :shelf` is what `#update` requires.
  Write the "(the chip list …)" placeholder above out in full from the old partial — it is not a
  placeholder in the real file.

  `app/views/settings/shelves/index.html.erb` (replace):

```erb
<% content_for :title, "Shelves — Tinkerex" %>

<div class="page-head">
  <h1>Shelves</h1>
  <%= link_to "Settings", settings_path, class: "btn ghost small" %>
</div>

<p class="muted">
  A shelf is a folder inside each project, <code>Projects/&lt;your project&gt;/&lt;shelf&gt;/</code>.
  A file left loose in a project folder is filed onto the shelf its extension names here, and an
  extension with no shelf goes to <code>other</code>. A file already in <code>other</code> moves out
  on the next sweep once its extension gets a shelf. A shelf's view is how its panel opens on a
  project page, and a group puts its shelves' panels together under one heading.
</p>

<% if @ungrouped.any? %>
  <div class="filing-cards">
    <%= render partial: "shelf_card", collection: @ungrouped, as: :shelf,
               locals: { by_folder: @by_folder, groups: @groups } %>
  </div>
<% end %>

<% @groups.each do |group| %>
  <section class="shelf-group" aria-labelledby="shelf-group-<%= group.id %>">
    <div class="shelf-group-bar">
      <h2 class="group-head" id="shelf-group-<%= group.id %>"><%= group.name %></h2>
      <%= form_with model: group, url: settings_shelf_group_path(group), scope: :shelf_group,
                    method: :patch, class: "shelf-group-rename" do |f| %>
        <%= f.text_field :name, id: nil, required: true, maxlength: Maker::ShelfGroup::NAME_MAX,
                         "aria-label": "Rename #{group.name}" %>
        <%= f.submit "Rename", class: "btn ghost small" %>
      <% end %>
      <%= button_to "Delete group", settings_shelf_group_path(group), method: :delete,
                    class: "linkbtn danger small",
                    form: { data: { turbo_confirm: "Delete the #{group.name} group? " \
                                                    "Its shelves stay, ungrouped." } } %>
    </div>
    <% members = @by_group[group.id] || [] %>
    <% if members.any? %>
      <div class="filing-cards">
        <%= render partial: "shelf_card", collection: members, as: :shelf,
                   locals: { by_folder: @by_folder, groups: @groups } %>
      </div>
    <% else %>
      <p class="empty">No shelves in this group yet. Choose it in a shelf's Group menu.</p>
    <% end %>
  </section>
<% end %>

<div class="shelf-forms">
  <%= form_with url: settings_shelves_path, scope: :shelf, class: "settings-add shelf-new" do |f| %>
    <label>
      <span>New shelf</span>
      <%= f.text_field :name, required: true, placeholder: "renders", id: nil %>
    </label>
    <%= f.submit "Add shelf", class: "btn primary" %>
  <% end %>
  <%= form_with url: settings_shelf_groups_path, scope: :shelf_group,
                class: "settings-add shelf-group-new" do |f| %>
    <label>
      <span>New group</span>
      <%= f.text_field :name, required: true, placeholder: "Fabrication",
                       maxlength: Maker::ShelfGroup::NAME_MAX, id: nil %>
    </label>
    <%= f.submit "Add group", class: "btn ghost" %>
  <% end %>
</div>
```

  Delete `settings/filing_rules/index.html.erb` and `_folder_card.html.erb`.

  `pages/settings.css` — read the file's structure first (its `@layer pages` wrapper) and add,
  after the `.filing-*` rules:

```css
  /* Shelves (2026-10-20): a card's head row, its view/group form, a group's bar, the two add
     forms. The cards themselves are the Filing page's `.filing-card`, unchanged. */
  .shelf-card-head { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
  .shelf-card-head form { display: inline; margin: 0; }
  .shelf-settings { display: flex; flex-wrap: wrap; align-items: end; gap: 8px; margin-top: 10px; }
  .shelf-settings label { display: grid; gap: 2px; font-size: 12px; }
  .shelf-group { margin-top: var(--space-5); }
  .shelf-group-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin-bottom: 10px; }
  .shelf-group-bar .group-head { margin: 0; }
  .shelf-group-bar form { display: inline-flex; gap: 6px; margin: 0; }
  .shelf-forms { display: flex; flex-wrap: wrap; gap: 16px; margin-top: var(--space-5); }
```

  In `pages/models.css` delete the old `.shelf-list`/`.shelf-path`/`.shelf-status`/`.shelf-add`
  rules with their comment, and the `.models-shelves-hint` rule with its comment. In
  `files/models/index.html.erb` delete the hint `<p>` and its ERB comment.

  `settings/show.html.erb`: delete the Filing `<li>`. The Shelves `<li>` stays as it is.

  `help/show.html.erb` — the models section becomes:

```erb
  <section aria-labelledby="models">
    <h2 id="models">3D models</h2>
    <p>The <%= link_to "3D models", files_models_path %> view gathers your 3D files into models. A
      3D file loose at the top of the library, in a top-level folder, in <code>Models/</code> or in
      a project's <code>models/</code> folder is a model of its own, and a folder inside one of
      those is one model holding what is inside it. A project's own folder is never a model, and
      removing a model from the catalog leaves its files where they are.</p>
  </section>
```

  and line ~79's `link_to "Filing", settings_filing_rules_path` becomes
  `link_to "Shelves", settings_shelves_path` (re-read the sentence so it still reads: "following
  the rules in Shelves"). `shared/_where_files_come_from.html.erb` the same: "your Shelves settings
  decide which type goes where." Also update the help page's own header comment (line ~9) if it
  names filing.

  Comments: `shell_helper.rb` (lines ~19-31: drop `settings/filing_rules` from the lit list and the
  shelves history sentence becomes one line saying `/settings/shelves` is the Shelves page);
  `filing_rules.rb` (its seed comment cites `Maker::Shelf.seed_once!` and
  `users.shelves_seeded_at` — both gone; rewrite that paragraph to compare against nothing, keeping
  the accepted-gap argument). `grep -rn "seed_once\|shelves_seeded_at\|Maker::Shelf\b\|/settings/filing\|settings_filing_rules_path" app lib config docs/invariants test`
  and fix every hit that describes the old shapes.

- [ ] **Step 8: Request tests.** `git mv` the filing test to `settings_shelves_test.rb`, rename the
  class to `SettingsShelvesTest`, rewrite its header comment, and:
  - every `get settings_filing_rules_path` → `get settings_shelves_path`; `assert_select "h1",
    "Filing"` → `"Shelves"`; every `assert_redirected_to settings_filing_rules_path` →
    `settings_shelves_path`;
  - "one card per folder, in the seed's own order": unchanged — the rendered order is still
    exactly `ROLE_FOLDERS.values.uniq`, `other` last;
  - "a custom folder a user's rules name gets a card of its own": unchanged in intent;
  - add:

```ruby
    test "/settings/filing redirects to the Shelves page" do
      get "/settings/filing"
      assert_redirected_to "/settings/shelves"
      assert_equal 301, response.status
    end

    # ASSERT THE RENDERED FIELD NAMES (§14d) for every new form on the page.
    test "the shelf, group and per-card forms post what the controllers read" do
      group = @user.maker_shelf_groups.create!(name: "Fabrication")
      get settings_shelves_path
      assert_select "form.shelf-new[action=?] input[name=?]", settings_shelves_path, "shelf[name]"
      assert_select "form.shelf-group-new[action=?] input[name=?]", settings_shelf_groups_path, "shelf_group[name]"
      assert_select "form.shelf-settings select[name=?]", "shelf[default_view]"
      assert_select "form.shelf-settings select[name=?]", "shelf[shelf_group_id]"
      assert_select "form.shelf-group-rename[action=?] input[name=?]", settings_shelf_group_path(group), "shelf_group[name]"
    end

    test "adding a shelf makes a card for it" do
      post settings_shelves_path, params: { shelf: { name: "Renders" } }
      assert_redirected_to settings_shelves_path
      assert @user.maker_shelves.exists?(name: "renders")
      follow_redirect!
      assert_includes css_select(".filing-card .filing-folder").map { |el| el.text.strip }, "renders/"
    end

    test "a bad shelf name is refused with the model's error" do
      post settings_shelves_path, params: { shelf: { name: "a/b" } }
      assert_redirected_to settings_shelves_path
      assert_match(/can't be a folder name/, flash[:alert])
    end

    test "a shelf's view and group are saved" do
      Maker::Shelves.ensure!(@user)
      group = @user.maker_shelf_groups.create!(name: "Fabrication")
      laser = @user.maker_shelves.find_by!(name: "laser")
      patch settings_shelf_path(laser), params: { shelf: { default_view: "list", shelf_group_id: group.id } }
      assert_equal [ "list", group.id ], laser.reload.then { [ _1.default_view, _1.shelf_group_id ] }
      patch settings_shelf_path(laser), params: { shelf: { default_view: "", shelf_group_id: "" } }
      assert_equal [ nil, nil ], laser.reload.then { [ _1.default_view, _1.shelf_group_id ] }
    end

    test "another user's group cannot be chosen" do
      Maker::Shelves.ensure!(@user)
      theirs = other_user!.maker_shelf_groups.create!(name: "Theirs")
      laser = @user.maker_shelves.find_by!(name: "laser")
      patch settings_shelf_path(laser), params: { shelf: { shelf_group_id: theirs.id } }
      assert_nil laser.reload.shelf_group_id
      assert_match(/isn't one of your groups/, flash[:alert])
    end

    test "removing a shelf removes its rules, so its extensions file into other" do
      Maker::Shelves.ensure!(@user)
      laser = @user.maker_shelves.find_by!(name: "laser")
      assert @user.maker_filing_rules.exists?(folder: "laser")
      delete settings_shelf_path(laser)
      assert_not @user.maker_shelves.exists?(name: "laser")
      assert_not @user.maker_filing_rules.exists?(folder: "laser")
      get settings_shelves_path
      assert_not @user.maker_shelves.exists?(name: "laser"), "a visit must not bring it back"
    end

    test "other cannot be removed" do
      Maker::Shelves.ensure!(@user)
      delete settings_shelf_path(@user.maker_shelves.find_by!(name: "other"))
      assert @user.maker_shelves.exists?(name: "other")
      assert_match(/can't be removed/, flash[:alert])
    end

    test "another user's shelf cannot be changed or removed" do
      theirs = other_user!.maker_shelves.create!(name: "laser")
      patch settings_shelf_path(theirs), params: { shelf: { default_view: "list" } }
      assert_response :not_found
      delete settings_shelf_path(theirs)
      assert_response :not_found
      assert Maker::Shelf.exists?(theirs.id)
    end

    test "groups are added, renamed and removed, and removing one keeps its shelves" do
      post settings_shelf_groups_path, params: { shelf_group: { name: "Fabrication" } }
      group = @user.maker_shelf_groups.find_by!(name: "Fabrication")
      patch settings_shelf_group_path(group), params: { shelf_group: { name: "Making" } }
      assert_equal "Making", group.reload.name
      shelf = @user.maker_shelves.create!(name: "laser", shelf_group: group)
      delete settings_shelf_group_path(group)
      assert_nil shelf.reload.shelf_group_id
    end

    test "a group's shelves render under its heading" do
      Maker::Shelves.ensure!(@user)
      group = @user.maker_shelf_groups.create!(name: "Fabrication")
      @user.maker_shelves.find_by!(name: "laser").update!(shelf_group: group)
      get settings_shelves_path
      section = css_select("section.shelf-group").find { |s| s.at_css(".group-head").text.include?("Fabrication") }
      assert_equal [ "laser/" ], section.css(".filing-folder").map { |el| el.text.strip }
    end
```

  Run these with `-n` filters as you go if useful. If a 404 from `find` is surfaced as an exception
  rather than a response in this suite, follow how the existing "another user's filing rule cannot
  be removed" test asserts it.

  Other tests:
  - delete `test/integration/web/shelves_test.rb` (the old page);
  - `settings_hub_test.rb`: the names list loses "Filing"; its setup's
    `maker_shelves.create!(path:)` becomes `create!(name: "renders")`/`create!(name: "prints")`;
    fix its header comment;
  - `page_query_budget_test.rb`: delete "shelves#index does not grow with shelves or
    directories"; in "settings#show does not grow…" use `create!(name: "#{prefix}shelf#{i}")`;
    find the Filing page's budget test (it grows folders) and point it at `settings_shelves_path`,
    growing shelves AND groups (`create!(name: "#{prefix}g#{i}")` with a shelf in each) so a
    per-card or per-group query would show;
  - `help_page_test.rb`: the words list's `Filing` → `Shelves`; drop `settings_filing_rules_path`
    from the paths list;
  - `moved_reference_pages_test.rb` and `models_redirects_test.rb:88`: read what each asserts about
    `/settings/shelves` and the 3D models page's link to it; the page still exists at the same path
    and `/models/shelves` still redirects there, so only an assertion about the removed hint or the
    old page's heading/content changes.

- [ ] **Step 9: Green** — run every test file listed in this task plus
  `test/integration/web/settings_reference_test.rb`, `shell_layout_test.rb`, `ci_hygiene_test.rb`,
  `css_hygiene_test.rb`, `stimulus_hygiene_test.rb`, `docs_hygiene_test.rb`. Mutation-check:
  - remove the fallback guard in `ShelvesController#destroy` → "other cannot be removed" red;
  - remove the `delete_all` line → "removing a shelf removes its rules" red;
  - change `scope: :shelf` to nothing on the settings form → the field-name test red.

- [ ] **Step 10: Commit**, message "Shelves: the filing folders, with a default view and groups".

---

### Task 5: The project page — shelf default views and group headings

**Files:**
- Modify: `app/services/maker/project_folder_listing.rb` (`panel_folders`, ~line 177-187)
- Modify: `app/services/maker/project_kind.rb` (`Layout`, `layout_for`)
- Modify: `app/helpers/projects_helper.rb`, `app/views/projects/_panel_groups.html.erb`,
  `app/views/projects/show.html.erb` (~line 231), `app/views/public/projects/_page.html.erb`
  (~line 219), `app/assets/stylesheets/pages/projects.css`
- Test: `test/services/maker/project_kind_test.rb`; create
  `test/integration/web/project_shelves_test.rb`

- [ ] **Step 1: Failing tests.** In `project_kind_test.rb` update the `panel_folders` test (~207)
  for the third element (nil when the user has no shelf rows for those names) and add:

```ruby
    def shelf(view: nil, group: nil, pos: nil) = Maker::Shelves::Entry.new(view:, group:, group_position: pos)

    test "a shelf's default view opens its folder's panel" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: {},
                                             folders: [ [ "n1", false, shelf(view: "list") ] ])
      assert_equal "list", layout.view_for("folder:n1")
    end

    test "a view chosen on the project outranks the shelf's" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: { "views" => { "folder:n1" => "browser" } },
                                             folders: [ [ "n1", false, shelf(view: "list") ] ])
      assert_equal "browser", layout.view_for("folder:n1")
    end

    test "an automatic shelf keeps the automatic default, browser for a working tree" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: {},
                                             folders: [ [ "n1", true, shelf ], [ "n2", false, nil ] ])
      assert_equal "browser", layout.view_for("folder:n1")
      assert_equal "tiles", layout.view_for("folder:n2")
    end

    test "a shelf view outside the vocabulary is dropped, not rendered" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: {},
                                             folders: [ [ "n1", false, shelf(view: "grid") ] ])
      assert_equal "tiles", layout.view_for("folder:n1")
    end

    test "a folder's shelf group is on the layout" do
      layout = Maker::ProjectKind.layout_for(kind: "other", overrides: {},
                                             folders: [ [ "n1", false, shelf(group: "Fabrication", pos: 0) ] ])
      assert_equal "Fabrication", layout.shelf_group_for("folder:n1")
      assert_nil layout.shelf_group_for("attachments")
    end
```

  Add a listing test (same file or the listing's own test file): folders `cnc`, `docs`, `laser`
  under a project (port-free: `project_folder_rows!` plus dir rows under it), shelves `laser` and
  `cnc` in group "Fabrication" (position 0), `docs` ungrouped → `panel_folders.map` of names reads
  `docs, cnc, laser` (ungrouped first, then the group in disk order).

  `test/integration/web/project_shelves_test.rb` (sign in with `sign_in_web!`; project folder via
  `project_folder_rows!` and child dir rows; give each folder one file row so its panel renders —
  read `project_page_test.rb` for how it builds a folder panel that renders on every backend):

```ruby
    test "a group's folder panels sit under one heading" do
      # folders: docs (no group), laser + cnc (group Fabrication)
      get project_path(@project)
      heads = css_select(".project-panels > .shelf-group-head").map { |h| h.text.strip }
      assert_equal [ "Fabrication" ], heads
      # the heading is immediately followed by the group's two panels
      # (assert on the sibling order of .project-panels' children, by the panels' folder names)
    end

    test "no heading when no shelf is grouped" do
      get project_path(@project)
      assert_select ".shelf-group-head", count: 0
    end

    test "a shelf's default view is the folder panel's view" do
      @user.maker_shelves.find_by!(name: "docs").update!(default_view: "list")
      get project_path(@project)
      # assert the docs folder panel rendered its LIST view: read projects/_folder_panel.html.erb
      # for the markup that differs between tiles and list and assert that.
    end
```

  Fill in the two "assert …" comments with real assertions once you have read the markup.

- [ ] **Step 2: Run; expect red.**

- [ ] **Step 3: Implement.** `project_folder_listing.rb`:

```ruby
    # THE PANEL LAYOUT'S VOCABULARY OF FOLDERS: `[[node_id, repo?, shelf], …]` for the DEPTH-ONE
    # subfolders. (keep the existing depth-one paragraph)
    #
    # `shelf` IS THE FOLDER'S Maker::Shelves::Entry BY NAME, or nil (2026-10-20): its default view
    # and its group. ORDER: ungrouped folders first in `tree`'s order, then each group's folders
    # together, by group position, so a group's panels are adjacent in the DEFAULT arrangement and
    # one heading can stand over them. A maker's saved order still wins (ProjectKind.stored_order).
    #
    # ONE QUERY, memoised on the listing (Maker::Shelves.by_name), constant in the folder count.
    def panel_folders
      tree.each_with_index
          .sort_by { |d, i| e = shelf_entries[d.name]; [ e&.group ? 1 : 0, e&.group_position || 0, e&.group.to_s, i ] }
          .map { |d, _i| [ d.node_id, d.repo?, shelf_entries[d.name] ] }
    end

    def shelf_entries = @shelf_entries ||= Maker::Shelves.by_name(@user)
```

  `project_kind.rb` — `Layout` gains two members with defaults, so `Data#with` and any existing
  `Layout.new` keep working:

```ruby
    Layout = Data.define(:order, :hidden, :views, :widths, :titles, :intros, :repo_ids, :block_kinds,
                         :shelf_views, :shelf_groups) do
      # SHELVES ARE OPTIONAL (2026-10-20): a caller with no shelves passes none.
      def initialize(shelf_views: {}, shelf_groups: {}, **rest) = super(shelf_views:, shelf_groups:, **rest)
```

  `view_for` becomes
  `views[key.to_s] || shelf_views[key.to_s] || ProjectKind.default_view(key.to_s, repo: …)` (same
  repo argument as today) with one comment line saying the order — the project's choice, the
  shelf's default, the automatic default. Add
  `def shelf_group_for(key) = shelf_groups[key.to_s]`. In `layout_for`:

```ruby
      shelf_views = Array(folders).filter_map do |id, _repo, shelf|
        [ folder_key(id), shelf.view ] if shelf&.view && Maker::Project::VIEWS.include?(shelf.view)
      end.to_h
      shelf_groups = Array(folders).filter_map { |id, _repo, shelf| [ folder_key(id), shelf.group ] if shelf&.group }.to_h
```

  and pass both into `Layout.new`. Update the `layout_for` / `folders:` comments
  (`[[node_id, repo?]]` → triples) here and in `app/models/maker/project.rb#panel_layout`.

  `projects_helper.rb`:

```ruby
  # THE SHELF-GROUP HEADINGS (2026-10-20). Yields each key for its slot markup and draws a heading
  # before every run of consecutive RENDERED panels whose folder's shelf is in the same group. A
  # panel that renders nothing (the visitor's page omits empty ones) neither draws nor breaks a
  # run, which is why the heading is decided here, after the body is known, and not from the keys.
  def panels_with_group_heads(keys, layout)
    previous = nil
    parts = keys.filter_map do |key|
      body = yield(key)
      next if body.blank?

      group = layout.shelf_group_for(key)
      head = tag.h2(group, class: "group-head shelf-group-head") if group && group != previous
      previous = group
      safe_join([ head, body ].compact)
    end
    safe_join(parts)
  end
```

  `_panel_groups.html.erb`: add `layout` to the documented locals; in the no-tabs branch replace
  `<% groups.top.each do |key| %><%= yield key %><% end %>` with
  `<%= panels_with_group_heads(groups.top, layout) { |key| yield key } %>`; in the tabs branch the
  `head = capture …` becomes `head = panels_with_group_heads(groups.top, layout) { |key| yield key }`
  and each pane's body becomes one `panels_with_group_heads(tab.keys, layout) { |key| yield key }`
  string (keep `panes` = tabs whose body is present, and render `<%= body %>` inside the pane's
  grid). Each key is still yielded once. Both callers pass `layout:` —
  `projects/show.html.erb` passes `@panel_layout`, `public/projects/_page.html.erb` passes
  `pub.layout`.

  `pages/projects.css`, next to the `.project-panels > .panel` rule (outside the media query):

```css
  /* A SHELF GROUP'S HEADING (2026-10-20, ProjectsHelper#panels_with_group_heads) spans the grid
     above its panels, on one column and two. */
  .project-panels > .shelf-group-head { grid-column: 1 / -1; margin: 8px 0 0; }
```

- [ ] **Step 4: Green**, plus `project_page_test.rb`, `page_query_budget_test.rb` (project pages),
  every `test/integration/web/public_*project*` test, `test/system/page_tabs_test.rb` and
  `test/system/page_editor_test.rb` (the editor's saved views are unchanged), and
  `template_hygiene_test.rb`. Mutation-check: drop `shelf_views[key.to_s] ||` → the shelf-view
  test red; make the helper draw the heading for every grouped panel (remove `group != previous`)
  → the one-heading assertion red; remove the `sort_by` → the order test red.

- [ ] **Step 5: Commit**, message "Project pages open a shelf's folder in its default view and group
  its panels".

---

### Task 6: "Use this view as preview" — the door and the viewer

**Files:**
- Modify: `config/routes.rb` (after the per-file links routes, ~line 196)
- Create: `app/controllers/files/previews_controller.rb`
- Modify: `app/views/files/viewers/_model3d.html.erb`, `app/views/files/show.html.erb` (~line
  146), `app/views/models/show.html.erb` (~lines 51-91),
  `app/javascript/controllers/modelviewer_controller.js`, the stylesheet that holds
  `.model-viewer-dims` (`grep -rn "model-viewer-dims" app/assets/stylesheets`)
- Test: create `test/integration/web/file_preview_test.rb`; add to `test/system/o3dv_test.rb`

- [ ] **Step 1: Routes.**

```ruby
  # --- A file's preview chosen in the 3D viewer (2026-10-20; keyed by node_id, session auth) ---
  # The node_id shape of the notes and links routes above. POST takes the viewer's PNG; DELETE
  # hands the thumbnail back to the server renderer (Files::PreviewsController).
  post   "files/:node_id/preview", to: "files/previews#create",  as: :file_preview
  delete "files/:node_id/preview", to: "files/previews#destroy"
```

- [ ] **Step 2: Failing request tests** — `test/integration/web/file_preview_test.rb`. Pin share
  (`@root = use_fresh_share_library!`) so the node is a real file on every leg; sign in with
  `sign_in_web!`; create the node with `create_node!` (test_helper) or `MeshFixture#write_model!`.

```ruby
require "test_helper"

module Web
  # "USE THIS VIEW AS PREVIEW" (2026-10-20): Files::PreviewsController. Share is pinned on all three
  # legs: the door stats the node through the port for its content token.
  class FilePreviewTest < ActionDispatch::IntegrationTest
    PNG_1PX = Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    ).freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "fp-#{SecureRandom.hex(4)}@example.com", password: WEB_PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user)
      @node = # a real file named "part.stl" under @root, through this suite's helper
    end

    def upload(bytes, type = "image/png")
      Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: "preview.png")
    end

    def token = FileLayer.current.stat(@user, @node.node_id).content_token

    test "a PNG becomes the file's thumbnail, marked as the viewer's, at the file's current content" do
      post file_preview_path(@node.node_id), params: { image: upload(PNG_1PX) }, as: :multipart,
           headers: { "Accept" => "application/json" }
      assert_response :created
      row = @user.maker_previews.find_by!(node_id: @node.node_id, kind: "thumbnail")
      assert_equal [ "viewer", "ready", token, 1, 1 ], [ row.source, row.status, row.version_id, row.width, row.height ]
      assert row.asset.attached?
      assert_equal row, Maker::Previews::Enqueue.current_preview(user: @user, node_id: @node.node_id,
                                                                  name: @node.name, version_id: token, kind: "thumbnail")
    end

    test "anything but a PNG is refused and nothing is written" do
      post file_preview_path(@node.node_id), params: { image: upload("GIF89a....", "image/gif") },
           headers: { "Accept" => "application/json" }
      assert_response :unprocessable_entity
      assert_not @user.maker_previews.exists?(node_id: @node.node_id, source: "viewer")
    end

    test "an oversized PNG is refused" do
      big = PNG_1PX.dup.tap { |b| b[16, 8] = [ 4096, 4096 ].pack("NN") }
      post file_preview_path(@node.node_id), params: { image: upload(big) },
           headers: { "Accept" => "application/json" }
      assert_response :unprocessable_entity
    end

    test "another user's file is not found" do
      other = User.create!(email: "fpo-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current, omniauth_signup: true)
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "x.stl", kind: "file", size: 1, mtime: 1)
      post file_preview_path(theirs.node_id), params: { image: upload(PNG_1PX) },
           headers: { "Accept" => "application/json" }
      assert_response :not_found
    end

    test "back to automatic hands the row to the renderer and queues a render" do
      post file_preview_path(@node.node_id), params: { image: upload(PNG_1PX) },
           headers: { "Accept" => "application/json" }
      assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
        delete file_preview_path(@node.node_id)
      end
      row = @user.maker_previews.find_by!(node_id: @node.node_id, kind: "thumbnail")
      assert_equal [ "renderer", "rebuilding" ], [ row.source, row.status ]
      assert_redirected_to file_path(@node.node_id)
    end

    test "the file page offers both buttons only to its owner, and Back only for a viewer preview" do
      get file_path(@node.node_id)
      assert_select "[data-modelviewer-preview-url-value=?]", file_preview_path(@node.node_id)
      assert_select "button[data-action=?]", "modelviewer#usePreview"
      assert_select "form[action=?] input[name=_method][value=delete]", file_preview_path(@node.node_id), count: 0
      post file_preview_path(@node.node_id), params: { image: upload(PNG_1PX) },
           headers: { "Accept" => "application/json" }
      get file_path(@node.node_id)
      assert_select "form[action=?] input[name=_method][value=delete]", file_preview_path(@node.node_id)
    end
  end
end
```

  Fill in `@node =` with the helper call (it is the one line left to the implementer because the
  two helpers differ in signature — read both). If `as: :multipart` is not needed with an
  UploadedFile param in this Rails version, drop it. Also assert the public file page
  (`public/files/view.html.erb`, which renders the same partial) carries no
  `data-modelviewer-preview-url-value` — find how `public_files_*` tests reach that page and add one
  assertion there.

- [ ] **Step 3: Controller** `app/controllers/files/previews_controller.rb`:

```ruby
module Files
  # "USE THIS VIEW AS PREVIEW" (2026-10-20). The 3D viewer renders the angle the maker chose as a
  # 512px PNG and posts it here; it becomes the file's thumbnail (Maker::Preview, source
  # "viewer") until the file's content changes, because Maker::Previews::Enqueue treats a viewer
  # row whose content token still matches as current. Session auth (§14d).
  #
  # THE PNG PASSES THROUGH RAILS, AND §15 PERMITS IT: §15 keeps LIBRARY bytes out of Rails; a
  # preview is app-owned derived data in Active Storage, the same thing POST /v1/maker/previews
  # already accepts from a device.
  class PreviewsController < ApplicationController
    MAX_BYTES = 2.megabytes
    MAX_SIDE = 1024
    PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze

    def create
      node = live_file!
      upload = params[:image]
      return refuse("Choose an image to use as the preview.") unless upload.respond_to?(:read)
      return refuse("The preview image is too large.") if upload.size > MAX_BYTES

      bytes = upload.read.b
      width, height = png_size(bytes)
      return refuse("The preview must be a PNG image.") if width.nil?
      return refuse("The preview image is too large.") if width > MAX_SIDE || height > MAX_SIDE

      token = FileLayer.current.stat(current_user, node.node_id).content_token
      preview = current_user.maker_previews.find_or_initialize_by(node_id: node.node_id, kind: "thumbnail")
      preview.assign_attributes(
        source: "viewer", status: "ready", version_id: token, width:, height:, error: nil,
        renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail")
      )
      preview.asset.attach(io: StringIO.new(bytes), filename: "thumbnail-viewer-#{preview.node_id}.png",
                           content_type: "image/png")
      preview.save!

      respond_to do |f|
        f.json { render json: { url: url_for(preview.asset) }, status: :created }
        f.html { redirect_to file_path(node.node_id), notice: "Preview saved." }
      end
    rescue FileLayer::FetchError
      refuse("The library isn't reachable right now. Try again in a moment.", status: :service_unavailable)
    end

    # BACK TO THE RENDERER. `rebuilding`, not `pending`: the maker's picture stays up until the
    # render lands (Maker::Preview's `rebuilding` contract), then the job replaces it.
    def destroy
      node = live_file!
      preview = current_user.maker_previews.find_by(node_id: node.node_id, kind: "thumbnail")
      if preview&.viewer?
        preview.update!(source: "renderer", status: "rebuilding")
        Maker::GeneratePreviewJob.perform_later(preview.id, filename: node.name)
      end
      redirect_to file_path(node.node_id), notice: "Back to the automatic preview."
    end

    private

    # SCOPED THROUGH current_user: a foreign or tombstoned node_id is a 404, never another
    # user's row.
    def live_file! = current_user.nodes.present.find_by!(node_id: params.require(:node_id), kind: "file")

    # [width, height] from the IHDR chunk, or nil when this is not a PNG.
    def png_size(bytes)
      return nil unless bytes.byteslice(0, 8) == PNG_MAGIC && bytes.byteslice(12, 4) == "IHDR"

      bytes.byteslice(16, 8).unpack("NN")
    end

    def refuse(message, status: :unprocessable_entity)
      respond_to do |f|
        f.json { render json: { error: message }, status: }
        f.html { redirect_to file_path(params[:node_id]), alert: message }
      end
    end
  end
end
```

  Check `FileLayer::FetchError` is the right constant name (`grep -rn "class FetchError"
  app/services/file_layer`) and how `FilesController` maps `FileLayer::NotFound` — mirror it for a
  file whose bytes vanished between the row and the stat.

- [ ] **Step 4: The views.** `_model3d.html.erb` strict-locals line gains
  `preview_url: nil, viewer_preview: false`; on the root `<div>` add
  `<% if preview_url %>data-modelviewer-preview-url-value="<%= preview_url %>"<% end %>`; in
  `.mv-actions` add, after Fullscreen:

```erb
      <% if preview_url %>
        <button type="button" class="btn small ghost" data-action="modelviewer#usePreview">Use this view as preview</button>
      <% end %>
```

  after the `</span>` that closes `.mv-actions`, add
  `<span class="mv-status muted" data-modelviewer-target="status" role="status"></span>`; and in
  the fallback, after the Download link:

```erb
    <% if preview_url && viewer_preview %>
      <%= button_to "Back to automatic preview", preview_url, method: :delete, class: "linkbtn small" %>
    <% end %>
```

  Extend the partial's header comment by two sentences (the button exists only when the caller
  passes `preview_url`, so a visitor's page never offers it). `files/show.html.erb` passes
  `preview_url: file_preview_path(@node.node_id), viewer_preview: @thumbnail&.viewer?`. Leave
  `public/files/view.html.erb` alone (it passes neither).

  `models/show.html.erb`: on the single-file branch add
  `data-modelviewer-preview-url-value="<%= file_preview_path(@viewable_3d.first[:node_id]) %>"`;
  on each `<option>` add `data-preview-url="<%= file_preview_path(f[:node_id]) %>"`; add the same
  "Use this view as preview" button in its `.mv-actions` and the same status `<span>`.

- [ ] **Step 5: The controller (JS).** In `modelviewer_controller.js`:
  - `static values` gains `previewUrl: String`; `static targets` gains `"status"`;
  - in `load()`, in the `if (this.hasSourceTarget …)` block, add
    `this.previewUrlValue = opt.dataset.previewUrl || ""` with the colours' comment's reasoning
    (the URL belongs to the FILE);
  - in `rest()` (find it) add `this.say("")`;
  - add at module level, below the imports:

```js
// THE PREVIEW IS SQUARE AND 512px, the size the server's thumbnails are rendered at.
const PREVIEW_SIZE = 512

// A data: URL to a Blob WITHOUT fetch(): the page's CSP `connect-src` does not list `data:`, so
// `fetch(dataUrl)` is refused; decoding by hand needs no policy at all.
function dataUrlToBlob(dataUrl) {
  const binary = atob(dataUrl.slice(dataUrl.indexOf(",") + 1))
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return new Blob([bytes], { type: "image/png" })
}
```

  - and the actions:

```js
  // "Use this view as preview" (2026-10-20): the engine draws the current camera into a square PNG
  // (o3dv's Viewer#GetImageAsDataUrl renders, reads the canvas and restores its size in one call,
  // so no preserveDrawingBuffer is needed) and Files::PreviewsController stores it as the file's
  // thumbnail. The poster behind the viewer takes the new picture at once; a page reload shows the
  // "Back to automatic preview" button the server renders for a viewer preview.
  async usePreview(event) {
    const button = event?.currentTarget
    const three = this.viewer?.GetViewer()
    if (!three || !this.previewUrlValue) return
    if (button) button.disabled = true
    this.say("Saving preview…")
    try {
      const dataUrl = three.GetImageAsDataUrl(PREVIEW_SIZE, PREVIEW_SIZE, false)
      const body = new FormData()
      body.append("image", dataUrlToBlob(dataUrl), "preview.png")
      const response = await fetch(this.previewUrlValue, {
        method: "POST",
        body,
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || ""
        }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const poster = this.hasFallbackTarget && this.fallbackTarget.querySelector("img")
      if (poster) poster.src = dataUrl
      this.say("Saved as the preview.")
    } catch (error) {
      console.warn("[modelviewer] could not save the preview:", error)
      this.say("Couldn't save the preview.")
    } finally {
      if (button) button.disabled = false
    }
  }

  say(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
```

  CSS beside `.model-viewer-dims`: `.mv-status { font-size: 12px; }` (and nothing that hides
  it — a status line must be readable while the viewer is open).

- [ ] **Step 6: System test** in `test/system/o3dv_test.rb` (it already pins share and signs in):

```ruby
  test "the current view becomes the file's preview" do
    node = write_model!(name: "bracket.stl", body: binary_stl)
    view_in_3d!(node)
    assert_rendered(MeshFixture::STL_DIMS)
    click_on "Use this view as preview"
    assert_selector ".mv-status", text: "Saved as the preview."
    row = @user.maker_previews.find_by!(node_id: node.node_id, kind: "thumbnail")
    assert_equal "viewer", row.source
    assert_equal [ 512, 512 ], [ row.width, row.height ]
    assert_no_console_errors
  end
```

  (If `devicePixelRatio` in the headless browser is not 1, o3dv still returns a 512px image — it
  divides by the ratio before resizing; if the measured size differs, report the numbers rather
  than loosening the assertion.)

- [ ] **Step 7: Green**, plus `test/stimulus_hygiene_test.rb`, `template_hygiene_test.rb`, every
  `public_*file*` request test, `test/system/o3dv_test.rb` whole, and `bin/ci scan` (brakeman).
  Mutation-check: drop the `PNG_MAGIC` comparison → the non-PNG test red; drop the size check →
  the oversized test red; drop `if preview_url` around the button → the public-page assertion red.

- [ ] **Step 8: Commit**, message "Use this view as preview: pick a file's preview angle in the 3D
  viewer".

---

### Task 7: Close-out (orchestrator)

- [ ] `git diff --stat origin/main -- app/ lib/ config/ db/` — only this plan's files.
- [ ] Bare `bin/ci` (export `TINKEREX_SYNC_DIR` if in a worktree). All gates green, three backend
  legs with equal RUN counts.
- [ ] Look at the pages in a browser (dev server recipe in memory): Settings → Shelves with a group;
  a project with grouped folders; the 3D models grid; a file page's "Use this view as preview".
- [ ] `/finish-branch` → PR. The PR states what was verified and what was not, and names the known
  limitation: saving a project's layout in the page editor stores each folder panel's current view
  (Maker::LayoutDocument writes `view_for`), so a later change to a shelf's default does not reach
  a project whose layout was saved after it.
- [ ] `bin/log arc --from-pr <n>`.
