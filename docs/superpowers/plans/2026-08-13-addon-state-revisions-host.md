# Addon State Revisions — Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A saved addon state becomes one row with a revision history, re-openable from a deep link and reachable from any library file it produced.

**Architecture:** `Maker::AddonState` stays one row per saved thing; a new `maker_addon_state_revisions` child table holds immutable param snapshots. The save door (`Tools::AddonsController#create`) gains an optional `state_id` that revises instead of creating, with one new rule: a destination collision with a node the target state already owns is an approved replace rather than a refusal. A new `Maker::AddonOrigin` service resolves library nodes back to the state that produced them in one query, feeding a right-click entry and a file-page button.

**Tech Stack:** Rails 8.1, Minitest, SQLite (dev/test) / Postgres (managed), Stimulus, importmap-pinned vanilla-JS SDK.

**Spec:** `docs/superpowers/specs/2026-08-13-addon-state-revisions-design.md`

---

## Before you start

Read the spec above in full — it carries the *arguments*, and several of them are the reason a step
below looks the way it does. Then read `CLAUDE.md` §14a (the FileLayer port), §14c (addons) and §14f
(project intake). This work touches the save door, which is the single most heavily-invarianted
method in the app.

Two rules from `CLAUDE.md` §15 that this plan depends on and does not restate per task:

- **Mutation-check every guard.** After a test that exists to *forbid* something goes green, break
  the thing it guards and confirm it goes **red**, then restore. Steps that require this say so.
- **Run the gates before you claim done.** `bin/ci` is the whole suite (~40 s per leg locally).

The three test legs must report **identical counts**:

```bash
bin/rails test
```

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
```

The s3 leg additionally needs the five `LIBRARY_S3_*` stub knobs — copy them verbatim from
`.github/workflows/ci.yml`'s `test-s3-backend` job.

---

## File structure

**Created**

| Path | Responsibility |
|---|---|
| `db/migrate/20260813000100_create_maker_addon_state_revisions.rb` | The table, the `revision` column on states, and the backfill |
| `db/migrate/20260813000200_add_node_id_index_to_maker_addon_files.rb` | The index the reverse lookup needs |
| `app/models/maker/addon_state_revision.rb` | One immutable param snapshot |
| `app/services/maker/addon_origin.rb` | node_ids → the state that produced each, in one query |
| `test/models/maker/addon_state_revision_test.rb` | Model + backfill guarantees |
| `test/services/maker/addon_origin_test.rb` | Reverse lookup, scoping, query count |

**Modified**

| Path | Change |
|---|---|
| `app/models/maker/addon_state.rb` | `has_many :revisions` |
| `app/services/maker/addons/host.rb` | `LEVEL` 2 → 3 |
| `app/controllers/tools/addons_controller.rb` | revise path, collision exemption, `#revisions`, `ctx.launch` |
| `config/routes.rb` | the revisions route |
| `app/javascript/maker/addon_sdk.js` | `stateId` on save, `state.revisions`, `host.launch` |
| `app/controllers/files_controller.rb` | `@addon_origins` on `#index` and `#show` |
| `app/controllers/projects_controller.rb` | `@addon_origins` on `#show` |
| `app/views/files/_list.html.erb`, `_grid.html.erb` | `data-addon-open-url` on the cell |
| `app/views/projects/_attachment_group.html.erb` | the same attribute |
| `app/views/files/show.html.erb` | the "Edit in …" button and the meta line |
| `app/javascript/controllers/filemenu_controller.js` | the "Edit in …" entry |
| `CLAUDE.md`, `docs/STATUS.md`, `docs/addon-api-v1.md` | the invariants and the author-facing contract |

---

### Task 1: The revisions table, model, and backfill

**Files:**
- Create: `db/migrate/20260813000100_create_maker_addon_state_revisions.rb`
- Create: `app/models/maker/addon_state_revision.rb`
- Modify: `app/models/maker/addon_state.rb`
- Test: `test/models/maker/addon_state_revision_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/maker/addon_state_revision_test.rb`:

```ruby
require "test_helper"

module Maker
  class AddonStateRevisionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "rev@example.com", password: "correct horse battery staple",
                           confirmed_at: Time.current)
      @state = @user.maker_addon_states.create!(
        addon_key: "boxes", name: "shelf box", data: { "generator" => "tray", "params" => { "h" => "60" } }
      )
    end

    test "a new state starts at revision 1" do
      assert_equal 1, @state.revision
    end

    test "revisions are unique per state" do
      @state.revisions.create!(revision: 1, data: @state.data)
      assert_raises(ActiveRecord::RecordNotUnique) do
        @state.revisions.insert!({ revision: 1, data: {}, created_at: Time.current })
      end
    end

    # A SNAPSHOT IS IMMUTABLE — there is no updated_at, so nothing can rewrite one and leave the
    # history disagreeing with itself. Asserted on the SCHEMA rather than on behaviour: a model
    # callback could be removed, a missing column cannot.
    test "a revision has no updated_at" do
      assert_not Maker::AddonStateRevision.column_names.include?("updated_at")
    end

    test "destroying a state destroys its revisions" do
      @state.revisions.create!(revision: 1, data: {})
      assert_difference -> { Maker::AddonStateRevision.count } => -1 do
        @state.destroy!
      end
    end

    # THE BACKFILL'S GUARANTEE, asserted as a property of the data rather than of the migration
    # file: every state has a revision-1 snapshot carrying the data it had at that moment. A state
    # created after the migration gets one from the save door (Task 2); one created here directly
    # does not, which is why this test seeds its own.
    test "a revision records the params as saved, not the state's later data" do
      @state.revisions.create!(revision: 1, data: @state.data)
      @state.update!(data: { "generator" => "tray", "params" => { "h" => "80" } }, revision: 2)
      @state.revisions.create!(revision: 2, data: @state.data)

      assert_equal "60", @state.revisions.find_by(revision: 1).data.dig("params", "h")
      assert_equal "80", @state.revisions.find_by(revision: 2).data.dig("params", "h")
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/models/maker/addon_state_revision_test.rb
```

Expected: every test errors with `NameError: uninitialized constant Maker::AddonStateRevision`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260813000100_create_maker_addon_state_revisions.rb`:

```ruby
# One immutable snapshot of a saved addon state's params. A state is ONE saved thing (a box, a
# drawing); a revision is what its params were at one save.
#
# NO `updated_at`, AND THAT IS THE POINT — a snapshot is never rewritten. `t.timestamps` would add
# one and quietly invite an `update!` that makes the history disagree with itself.
#
# `maker_addon_states.revision` IS THE CURRENT NUMBER AND THERE IS NO COUNT COLUMN: nothing deletes
# a revision, so the count equals the current number. Add a count column with the deletion, not
# before — two values to keep in step, for no present reader, is how they drift.
class CreateMakerAddonStateRevisions < ActiveRecord::Migration[8.1]
  def up
    create_table :maker_addon_state_revisions do |t|
      t.references :addon_state, null: false, foreign_key: { to_table: :maker_addon_states }
      t.integer :revision, null: false
      t.json :data, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :maker_addon_state_revisions, [ :addon_state_id, :revision ], unique: true,
              name: "index_maker_addon_state_revisions_on_state_and_revision"

    add_column :maker_addon_states, :revision, :integer, null: false, default: 1

    # BACKFILL: every existing state comes out of this migration with a coherent one-entry history
    # rather than an empty one. `created_at` is the STATE's own, not now() — the snapshot describes
    # a save that happened then. Written with the connection rather than the model so a later change
    # to Maker::AddonState cannot change what this migration did.
    say_with_time "backfilling revision 1 for existing addon states" do
      execute(<<~SQL.squish)
        INSERT INTO maker_addon_state_revisions (addon_state_id, revision, data, created_at)
        SELECT id, 1, data, created_at FROM maker_addon_states
      SQL
    end
  end

  def down
    remove_column :maker_addon_states, :revision
    drop_table :maker_addon_state_revisions
  end
end
```

- [ ] **Step 4: Write the model and the association**

Create `app/models/maker/addon_state_revision.rb`:

```ruby
module Maker
  # ONE IMMUTABLE SNAPSHOT of a saved state's params. Never updated: the row records what was saved
  # at revision N, and a later save appends N+1 rather than rewriting this one. There is no
  # `updated_at` column, so the schema enforces that rather than a callback somebody can remove.
  class AddonStateRevision < ApplicationRecord
    self.table_name = "maker_addon_state_revisions"
    # `record_timestamps` still sets created_at; there is simply no updated_at column to set.

    belongs_to :addon_state, class_name: "Maker::AddonState"

    validates :revision, presence: true, numericality: { only_integer: true, greater_than: 0 }
  end
end
```

In `app/models/maker/addon_state.rb`, add below the existing `has_many :files` line:

```ruby
    # THE HISTORY. Ordered oldest-first here; the endpoint that serves it reverses, because a
    # reader wants the newest revision at the top and a writer wants `maximum(:revision)`.
    has_many :revisions, -> { order(:revision) }, class_name: "Maker::AddonStateRevision",
             foreign_key: :addon_state_id, dependent: :destroy
```

- [ ] **Step 5: Migrate and run the test**

```bash
bin/rails db:migrate && bin/rails test test/models/maker/addon_state_revision_test.rb
```

Expected: 5 runs, 0 failures, 0 errors. `db/schema.rb` now shows version `2026_08_13_000100`.

- [ ] **Step 6: Prove the backfill actually ran**

The test above seeds its own revisions, so it cannot see a broken backfill. Prove it against a row
that predates the migration:

```bash
bin/rails runner '
  u = User.create!(email: "bf-#{SecureRandom.hex(3)}@example.com", password: "correct horse battery staple", confirmed_at: Time.current)
  s = u.maker_addon_states.create!(addon_key: "boxes", name: "pre-existing", data: {"params" => {"h" => "60"}})
  s.revisions.delete_all                                  # simulate a row that predates the migration
  ActiveRecord::Base.connection.execute("INSERT INTO maker_addon_state_revisions (addon_state_id, revision, data, created_at) SELECT id, 1, data, created_at FROM maker_addon_states WHERE id = #{s.id}")
  r = s.revisions.reload.first
  puts "revision=#{r.revision} h=#{r.data.dig("params","h")} created_matches=#{r.created_at.to_i == s.created_at.to_i}"
'
```

Expected: `revision=1 h=60 created_matches=true`.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260813000100_create_maker_addon_state_revisions.rb db/schema.rb app/models/maker/addon_state_revision.rb app/models/maker/addon_state.rb test/models/maker/addon_state_revision_test.rb
git commit -m "feat(addons): an addon state gets an immutable revision history"
```

---

### Task 2: The save door revises when handed a `state_id`

> **AS SHIPPED, THIS TASK DIVERGED FROM THE TEXT BELOW — read this before treating the code blocks
> here as a description of the tree.** Two changes came out of review and are the current truth:
>
> - The single `#revision_target` (which both resolved a value AND rendered) was split into a pure
>   `#resolve_revision_target` plus a sibling renderer `#render_no_such_state`, matching `#file`'s
>   existing house pattern, and `return if performed?` went with it. References to
>   `#revision_target` below are historical.
> - The `LibraryOutput` call uses `.slice(:parent_node_id, :replace)` — an **allowlist** — not the
>   `.except(:folder, :owned)` skip-list written below. `:owned` is produced by nothing until
>   Task 3, so a skip-list naming it could never be mutation-checked and would silently stop
>   covering it if Task 3 chose a different key (§14b's recorded blind spot).

**Files:**
- Modify: `app/controllers/tools/addons_controller.rb:389-442` (`#create`)
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `Tools::AddonsControllerTest` (after the existing `"save writes the file to the
library and records an AddonState"` test):

```ruby
    # ---- save: revising an existing state ------------------------------------------------

    # Saves once and returns the state, so each revision test starts from a real save rather than
    # a hand-built row — a fixture with no AddonFile rows cannot exercise the collision exemption
    # in Task 3, and a `nodes.create!` fixture has a NULL storage_path that cannot exist on
    # share/s3 (CLAUDE.md §14a).
    def save_box(name:, params: { "h" => "60" }, state_id: nil, file: "shelf-box.svg")
      post tools_addon_path("widgetkit"), params: {
        name:,
        data: { generator: "tray", params: }.to_json,
        files: [ { name: file, content_type: "image/svg+xml", body: "<svg/>" } ].to_json,
        **(state_id ? { state_id: } : {})
      }
      @user.maker_addon_states.order(:id).last
    end

    test "a save carrying state_id revises the box instead of creating a second one" do
      state = save_box(name: "shelf box")

      assert_no_difference -> { @user.maker_addon_states.count } do
        post tools_addon_path("widgetkit"), params: {
          name: "shelf box",
          data: { generator: "tray", params: { "h" => "80" } }.to_json,
          files: [ { name: "shelf-box.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json,
          state_id: state.id, overwrite: "1"
        }
      end
      assert_response :redirect

      state.reload
      assert_equal 2, state.revision
      assert_equal "80", state.data.dig("params", "h")
      assert_equal [ 1, 2 ], state.revisions.pluck(:revision)
      assert_equal "60", state.revisions.find_by(revision: 1).data.dig("params", "h")
      assert_equal "80", state.revisions.find_by(revision: 2).data.dig("params", "h")
    end

    # A REVISION RENAMES THE BOX. `name` is a property of the design, not of one snapshot.
    test "revising updates the box name" do
      state = save_box(name: "shelf box")
      post tools_addon_path("widgetkit"), params: {
        name: "shelf box mk2",
        data: { generator: "tray", params: { "h" => "80" } }.to_json,
        files: [ { name: "shelf-box-mk2.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json,
        state_id: state.id
      }
      assert_response :redirect
      assert_equal "shelf box mk2", state.reload.name
    end

    # 404 AND NO WRITE — never a 500, and never a silent fallback to creating a new box, which
    # would file a revision of someone else's design as a new one of yours.
    test "a state_id belonging to another user is a 404 and writes nothing" do
      other = User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "widgetkit", name: "not yours", data: {})

      assert_no_difference [ -> { @user.maker_addon_states.count }, -> { @user.nodes.count } ] do
        post tools_addon_path("widgetkit"), params: {
          name: "mine now",
          data: { generator: "tray", params: {} }.to_json,
          files: [ { name: "x.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json,
          state_id: theirs.id
        }
      end
      assert_response :not_found
      assert_equal 0, theirs.reload.revisions.count
    end

    test "an unknown state_id is a 404 and writes nothing" do
      assert_no_difference -> { @user.maker_addon_states.count } do
        post tools_addon_path("widgetkit"), params: {
          name: "ghost",
          data: { generator: "tray", params: {} }.to_json,
          files: [ { name: "x.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json,
          state_id: 999_999
        }
      end
      assert_response :not_found
    end

    # THE states_key SCOPE, NOT JUST THE USER SCOPE. A state saved under another addon's namespace
    # is not a target, or one addon could append revisions to another's saved work by id alone.
    test "a state_id from another addon's namespace is a 404" do
      foreign = @user.maker_addon_states.create!(addon_key: "someone-else", name: "theirs", data: {})
      post tools_addon_path("widgetkit"), params: {
        name: "mine",
        data: { generator: "tray", params: {} }.to_json,
        files: [ { name: "x.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json,
        state_id: foreign.id
      }
      assert_response :not_found
      assert_equal 0, foreign.reload.revisions.count
    end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/revis|state_id/"
```

Expected: the two 404 tests fail with `Expected response to be a <404>, but was <302>` (today an
unknown `state_id` is simply ignored), and the revise tests fail on
`Expected: 2, Actual: 1` for `state.revision` — or on the state count, since a second row is created.

- [ ] **Step 3: Implement the revise path**

In `app/controllers/tools/addons_controller.rb`, replace the body of `#create` between
`return head(:unprocessable_entity) if files.nil?` and the `ApplicationRecord.transaction do` block,
and replace the transaction block itself:

```ruby
      # THE TARGET OF A REVISION, or nil for a new box. Resolved BEFORE any write: a bad state_id
      # must cost nothing, and a 404 after a partial write would leave library bytes behind for a
      # save the caller was told did not happen.
      state = revision_target
      return if performed?

      parent_node_id = chosen_parent_node_id
      refuse_taken_names!(files, parent_node_id)
      placements = resolve_placements(files, parent_node_id)
      return if render_would_replace(files, placements)

      addon_files = nil
      ApplicationRecord.transaction do
        if state
          # A REVISION RENAMES THE BOX when the name changed — `name` is a property of the design,
          # not of one snapshot. The snapshot records `data` only.
          state.update!(name: params.require(:name), data: parse_data, revision: state.revision + 1)
        else
          state = current_user.maker_addon_states.create!(
            addon_key: @addon.states_key, name: params.require(:name), data: parse_data
          )
        end
        state.revisions.create!(revision: state.revision, data: state.data)
        addon_files = Maker::Addons::LibraryOutput.write(
          user: current_user, state:, parent_node_id:,
          files: files.each_with_index.map do |f, i|
            { name: f.name, bytes: f.bytes, content_type: f.content_type, role: "output" }
              .merge(placements[i].except(:folder, :owned))
          end
        )
      end
```

Note the `.except(:folder, :owned)` — `:owned` is added by Task 3 and must never reach
`LibraryOutput`, which would reject an unknown key silently by ignoring it. Adding it now means
Task 3 does not have to remember.

- [ ] **Step 3b: Make `LibraryOutput` upsert its `AddonFile` rows**

**Without this the revise tests fail with `ActiveRecord::RecordNotUnique`, not with an assertion.**
`maker_addon_files` has a unique index on `[addon_state_id, node_id]`, and a replace *keeps the
node* — so the second save of a box hands `LibraryOutput` a node_id its state already has a row for,
and `state.files.create!` violates that index with a 500.

In `app/services/maker/addons/library_output.rb`, replace the `state.files.create!(...)` line at the
end of `#write` with:

```ruby
          upsert_file!(state, node_id:, role: f[:role], content_type: f[:content_type], position: i)
```

and add to the module:

```ruby
      # UPSERT, NOT CREATE, BECAUSE A REPLACE KEEPS THE NODE. `maker_addon_files` is unique on
      # [addon_state_id, node_id], so the second save of a box — which rewrites the same node — hits
      # that index with a bare RecordNotUnique 500 if this creates blindly. Identical behaviour for
      # a first save: there is no row, so it creates one.
      #
      # A ROW WHOSE FILE THE BUNDLE STOPPED EMITTING IS LEFT ALONE, deliberately: that file is still
      # an ordinary library file the user may have renamed or attached to a project, and "a
      # migration must not delete user bytes" (CLAUDE.md §14c) binds a save door too. The row is the
      # only record that this state produced it.
      def upsert_file!(state, node_id:, role:, content_type:, position:)
        row = state.files.find_or_initialize_by(node_id:)
        row.update!(role:, content_type:, position:)
        row
      end
```

Then re-run the Task 2 tests — they should now fail on assertions (`Expected: 2, Actual: 1`) rather
than erroring.

Then add to the `private` section, next to `#load_addon`:

```ruby
    # THE STATE A SAVE REVISES, or nil when this is a new box.
    #
    # SCOPED BY `states_key`, NOT `key` — that is the DATA scope (the same one `#states` uses),
    # while `key` builds routes. Scoping by `key` would let a save under one addon append a
    # revision to a state filed under another's namespace whenever the two diverge.
    #
    # 404 AND NOT A SILENT FALLBACK TO CREATING. An id that does not resolve is a bundle bug or a
    # stale tab, and creating a new box instead would file a revision of an existing design as an
    # unrelated one — the pile-up this whole feature exists to end, reintroduced by the error path.
    def revision_target
      raw = params[:state_id]
      return nil if raw.blank?

      state = current_user.maker_addon_states.for_addon(@addon.states_key).find_by(id: raw)
      return state if state

      render json: { error: "not_found", message: "No such saved item for this addon." },
             status: :not_found
      nil
    end
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/revis|state_id/"
```

Expected: 5 runs, 0 failures, 0 errors.

- [ ] **Step 5: Run the whole addon suite for regressions**

```bash
bin/rails test test/controllers/tools/ test/models/maker/addon_state_test.rb
```

Expected: 0 failures. Every pre-existing save test sends no `state_id`, so it takes the create
branch unchanged.

- [ ] **Step 6: Mutation-check the `states_key` scope**

Change `.for_addon(@addon.states_key)` to `.all` in `#revision_target`, then:

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/another addon/"
```

Expected: **FAIL** (`Expected response to be a <404>, but was <302>`). Restore the scope and confirm
it passes again.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/tools/addons_controller.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): a save carrying state_id revises rather than creating a second box"
```

---

### Task 3: A collision with the box's own file is an approved replace

This is the guard the whole feature rests on, and the one most likely to be written so that it
cannot fail. Read spec §2 and §4.2 before starting.

**Files:**
- Modify: `app/controllers/tools/addons_controller.rb` (`#refuse_taken_names!`, `#resolve_placements`, `#render_would_replace`)
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

**REWRITTEN AFTER TASK 2 SHIPPED — read this before the code.** The original version of this step
was written against a `save_box` helper and a collision model that do not exist. Two things changed
and both affect every test below:

- **`save_box` asserts its own redirect** (`assert_redirected_to tools_addon_path("widgetkit")`)
  and returns the state the save *targeted*. So it can only be used for a save expected to
  **succeed**. Every refusal test below must `post` directly.
- **`save_box` generates a UNIQUE filename per call** (`file:` defaults to
  `"shelf-box-#{SecureRandom.hex(4)}.svg"`), because fixed names leak across tests on the share
  leg — the DB row rolls back on a refusal and the file on disk does not. Pass `file:` explicitly
  whenever a test needs two saves to collide.

There is also an existing Task 2 test, `"revising a filed output replaces it in place, keeping one
node and one file row"`, which reaches the replace through the **category folder** and needs
`overwrite: "1"` to get past the 409. **Task 3 is what makes that `overwrite: "1"` unnecessary** —
so part of your job is deleting that argument from that test and watching it still pass. That is
the single best proof the exemption works, because the test predates it.

Append to `Tools::AddonsControllerTest`, after the Task 2 block:

```ruby
    # ---- save: the collision exemption ---------------------------------------------------
    #
    # THE RULE, IN BOTH DIRECTIONS: a destination collision with a node the target state already
    # owns is an approved replace; every other collision keeps today's answer. The refusal tests
    # are what stop this from being "revising disables the collision checks".
    #
    # TWO FOLDERS, TWO CHECKS, AND BOTH NEED THE EXEMPTION. A box that was swept into a project's
    # category folder collides there, at `resolve_placements` (answerable, 409). A box sitting in
    # the plain folder the save dialog picked collides at `refuse_taken_names!` (terminal, 422) and
    # never reaches the other check at all — which is why exempting only one of them leaves the
    # mainline "open a saved design, tweak, re-save" flow still refused.

    test "revising replaces its own file in the picked folder, with no 422 and no overwrite flag" do
      file = "shelf-box-#{SecureRandom.hex(4)}.svg"
      state = save_box(name: "shelf box", file:)
      node_id = state.files.sole.node_id

      state = save_box(name: "shelf box", params: { "h" => "80" }, file:, state_id: state.id)

      assert_equal 2, state.reload.revision
      # THE NODE SURVIVES. A replace written as delete-then-create passes any bytes-oriented
      # assertion while orphaning every attachment, BOM link and tag (CLAUDE.md §14a).
      assert_equal [ node_id ], state.files.pluck(:node_id)
      assert @user.nodes.present.exists?(node_id:), "the node must still be live"
      assert_equal 1, @user.nodes.present.where(name: file).count, "no second copy"
      assert_equal "<svg/>", FileLayer.current.read(@user, node_id:)
    end

    test "revising still refuses a name owned by a file this box did not produce" do
      taken = "taken-#{SecureRandom.hex(4)}.svg"
      state = save_box(name: "shelf box")
      save_box(name: "unrelated", file: taken)   # a DIFFERENT state owns this name

      post tools_addon_path("widgetkit"), params: {
        name: "shelf box",
        data: { generator: "tray", params: { "h" => "80" } }.to_json,
        files: [ { name: taken, content_type: "image/svg+xml", body: "<svg/>" } ].to_json,
        state_id: state.id
      }

      assert_response :unprocessable_entity
      assert_equal "unsupported_operation", response.parsed_body["error"]
      assert_equal 1, state.reload.revision, "a refused save must not have counted as a revision"
    end

    # THE SAME REFUSAL ON THE OTHER CHECK: a name owned by another state, in a project's category
    # folder, is a 409 question rather than a 422 — and it must STAY a question, not become a
    # silent replace, just because this save named a state.
    test "revising still asks before replacing a filed file another box produced" do
      taken = "harbor-number-#{SecureRandom.hex(4)}.svg"
      _project, folder = project_with_filed(taken)
      state = save_box(name: "shelf box")   # a different state, owning nothing in that folder

      post tools_addon_path("widgetkit"), params: {
        name: "shelf box", data: "{}", parent_node_id: folder.node_id, state_id: state.id,
        files: [ { name: taken, content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      }

      assert_response :conflict
      assert_equal "would_replace", response.parsed_body["error"]
      assert_equal 1, state.reload.revision
    end

    # THE DEAD END THIS CLOSES (spec §1.3). WITHOUT a state_id, re-saving into the folder the file
    # already sits in is a terminal 422 that no confirmation can answer — that is the bug, and it
    # must stay refused for a save that does not name the state, or the exemption has become
    # "anyone may clobber anything".
    test "a re-save with no state_id is still refused, which is why revising exists" do
      file = "shelf-box-#{SecureRandom.hex(4)}.svg"
      save_box(name: "shelf box", file:)

      post tools_addon_path("widgetkit"), params: {
        name: "shelf box",
        data: { generator: "tray", params: { "h" => "80" } }.to_json,
        files: [ { name: file, content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      }
      assert_response :unprocessable_entity
    end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/collision|replaces its own file|refuses a name|asks before replacing|re-save with no/"
```

Expected: the first test fails inside `save_box`'s own `assert_redirected_to`, with the response a
**422** — today `refuse_taken_names!` refuses the box's own file. The three refusal tests already
pass; they are the guard rails that must *stay* passing, and if any of them goes red later in this
task you have written an exemption that is too wide.

- [ ] **Step 3: Implement the exemption**

In `app/controllers/tools/addons_controller.rb`, replace `#refuse_taken_names!`,
`#resolve_placements` and `#render_would_replace` with:

```ruby
    # THE (parent, name) PAIRS THE TARGET STATE ALREADY OWNS — what a revision is entitled to
    # overwrite, and nothing else. Empty for a new box, which is what keeps every existing caller's
    # behaviour byte-identical.
    #
    # KEYED BY (parent, name) RATHER THAN BY node_id because that is the question both collision
    # checks actually ask: "is something already at this destination?" A node_id set would still
    # need the destination lookup to compare against, and doing it here means one query for the
    # whole save instead of one per file.
    def owned_destinations(state)
      return {} if state.nil?

      node_ids = state.files.pluck(:node_id)
      return {} if node_ids.empty?

      current_user.nodes.present.where(node_id: node_ids)
                  .pluck(:parent_node_id, :name, :node_id)
                  .to_h { |parent, name, node_id| [ [ parent, name ], node_id ] }
    end

    # PER FILE, NOT PER SAVE, because one save can collide on some outputs and not others: the
    # boxes addon emits `<base>.svg` and `<base>-plan.svg` together, and a re-save can find the
    # first name taken in its category folder and the second free. That is why
    # Maker::Addons::LibraryOutput takes a per-file destination.
    #
    # THE DESTINATION IS THE OCCUPANT'S OWN PARENT, not a folder this method resolves separately —
    # there is an occupant, so its parent IS the category folder, already created. Nothing here
    # mkdirs: a save that needs a folder made still lands at the picked folder and the sweep files
    # it, exactly as before.
    #
    # `owned` MARKS A COLLISION THE CALLER ALREADY CONSENTED TO by naming this state — it still
    # sets `replace: true` (the write is a replace either way), and it is what keeps
    # #render_would_replace from asking a question whose answer the state_id already gave.
    def resolve_placements(files, parent_node_id, owned = {})
      files.map do |f|
        dest = Maker::ProjectIntake.destination_for(user: current_user, parent_node_id:,
                                                    name: f.name)
        occupied = dest&.occupied_by
        next {} unless occupied

        { folder: dest.folder, parent_node_id: occupied.parent_node_id, replace: true,
          owned: owned[[ occupied.parent_node_id, occupied.name ]] == occupied.node_id }
      end
    end

    # 409 when a save would replace something and the user has not said so. Answers true if it
    # rendered, so #create can return.
    #
    # 409, NOT THE 422 #refuse_taken_names! RAISES, and a bundle needs the two kept apart: 422
    # (`unsupported_operation`) means "that name is taken where you asked" and never succeeds on
    # retry, while 409 means "this WOULD replace something — resend with overwrite and it will".
    # One is an error to report, the other is a question to ask.
    #
    # THE BODY NAMES EVERY COLLIDING FILE AND ITS FOLDER, so the dialog can say which output it is
    # about — a multi-file save that reported only a count would make the user guess.
    #
    # OLD BUNDLES DEGRADE HONESTLY. They branch on `res.ok` alone, so a 409 reads as "Save failed."
    # — no dialog, but also no silent second copy stranded at the project root, which is what they
    # got before. The dialog itself ships in the bundle repo.
    #
    # AN `owned` PLACEMENT IS NEVER ASKED ABOUT: naming the state IS the consent, and asking again
    # would put a confirm dialog in front of the ordinary act of saving a design twice.
    def render_would_replace(files, placements)
      return false if params[:overwrite].present?

      colliding = files.zip(placements).select { |_f, p| p[:replace] && !p[:owned] }
      return false if colliding.empty?

      render json: { error: "would_replace",
                     files: colliding.map { |f, p| { name: f.name, folder: p[:folder] } } },
             status: :conflict
      true
    end

    # THE PICKED FOLDER's check, and the one a revision most often trips: a box that was never
    # swept into a project category folder is still sitting in the folder the save dialog defaults
    # to, so `resolve_placements` never sees it and this is the only check it meets.
    #
    # AN OWNED DESTINATION IS EXEMPT — and only an owned one. A name taken by a file this state did
    # not produce is still the terminal 422 it has always been, because no `overwrite` can make
    # somebody else's file the right thing to rewrite.
    def refuse_taken_names!(files, parent_node_id, owned = {})
      taken = files.map(&:name).select do |name|
        next false if owned.key?([ parent_node_id, name ])

        Maker::MoveNode.collision?(current_user, parent_node_id:, name:, except_node_id: nil)
      end
      return if taken.empty?

      raise FileLayer::UnsupportedOperation,
            "#{taken.map(&:inspect).join(', ')} already #{taken.one? ? 'exists' : 'exist'} in that " \
            "folder. Rename the save or pick another folder."
    end
```

Then wire the call sites in `#create`. **Task 2 changed the surrounding lines**, so read the method
as it actually is now rather than pattern-matching this snippet: `state` is resolved above by
`resolve_revision_target` (pure) plus a `return render_no_such_state if state.nil?` guard, and the
`LibraryOutput` call already uses `.slice(:parent_node_id, :replace)` — an **allowlist**, so your
new `:owned` key is dropped there automatically and you must NOT add it to any `except`.

```ruby
      parent_node_id = chosen_parent_node_id
      owned = owned_destinations(state)
      refuse_taken_names!(files, parent_node_id, owned)
      placements = resolve_placements(files, parent_node_id, owned)
      return if render_would_replace(files, placements)
```

- [ ] **Step 3b: Delete the `overwrite: "1"` that Task 2 needed**

`"revising a filed output replaces it in place, keeping one node and one file row"` currently passes
`overwrite: "1"` to get past the 409 on its own file. **That is exactly what this task removes the
need for.** Delete the argument and confirm the test still passes.

This is the strongest single piece of evidence in the task, because that test predates the
exemption and was not written to prove it. Update its comment to say the overwrite is no longer
needed and why.

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb
```

Expected: 0 failures, 0 errors across the whole file.

- [ ] **Step 5: Mutation-check the exemption in BOTH directions, on BOTH checks**

Four mutations, because the exemption lives in two places and each can fail in two directions. A
mutation that leaves every test green means the assertion it should have broken does not exist —
that is a finding, not a pass.

**1. Remove the exemption from the picked-folder check** — delete the `next false if owned.key?(...)`
line in `#refuse_taken_names!`:

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/replaces its own file/"
```

Expected: **FAIL**. Restore.

**2. Remove the exemption from the category-folder check** — make `resolve_placements` always set
`owned: false`:

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/revising a filed output/"
```

Expected: **FAIL** (a 409 where a redirect belongs) — this is the test whose `overwrite: "1"` you
deleted in Step 3b. Restore.

**3. Make the picked-folder exemption unconditional** — the direction that matters, since it
silently lets a revision overwrite a stranger's file. Change the guard to `next false if owned.any?`:

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/refuses a name/"
```

Expected: **FAIL**. Restore.

**4. Make the category-folder exemption unconditional** — set `owned: true` unconditionally in
`resolve_placements`:

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/asks before replacing/"
```

Expected: **FAIL** (a redirect where a 409 belongs). Restore, and confirm the whole file is green.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/tools/addons_controller.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): a revision may replace its own files, and only its own"
```

---

### Task 4: `Host::LEVEL` 3 and `revision` in the states payload

**Files:**
- Modify: `app/services/maker/addons/host.rb:24`
- Modify: `app/controllers/tools/addons_controller.rb:269-276` (`#states`)
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
    test "the states payload carries the current revision number" do
      state = save_box(name: "shelf box")
      get tools_addon_states_path("widgetkit")
      assert_response :success
      assert_equal 1, response.parsed_body.first["revision"]

      save_box(name: "shelf box", state_id: state.id)
      get tools_addon_states_path("widgetkit")
      assert_equal 2, response.parsed_body.first["revision"]
    end

    # ONE ENTRY PER BOX, FOR THE LIFE OF api_version 1. This is what lets every already-published
    # bundle keep working across this change: a revision must never look like a second saved thing.
    test "revising does not add a states entry" do
      state = save_box(name: "shelf box")
      save_box(name: "shelf box", state_id: state.id)
      get tools_addon_states_path("widgetkit")
      assert_equal 1, response.parsed_body.length
    end

    # ADDITIVE KEYS ONLY. Pinned as a set so a REMOVED or RENAMED key — the change a published
    # bundle would break on — goes red here, where nothing else in this repo can see it.
    test "the states payload keeps every key a published bundle reads" do
      save_box(name: "shelf box")
      get tools_addon_states_path("widgetkit")
      entry = response.parsed_body.first
      assert_equal %w[data files id name revision updated_at], entry.keys.sort
      assert_equal %w[node_id role], entry["files"].first.keys.sort
    end

    test "the host announces level 3" do
      get tools_addon_path("widgetkit")
      ctx = JSON.parse(css_select("[data-addon-ctx-value]").first["data-addon-ctx-value"])
      assert_equal 3, ctx["hostLevel"]
    end
```

- [ ] **Step 2: Run and watch fail**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/revision number|does not add a states|keeps every key|level 3/"
```

Expected: `revision` missing from the payload (nil vs 1), key set mismatch, and `2` vs `3` for the
host level.

- [ ] **Step 3: Implement**

In `app/services/maker/addons/host.rb`, replace the `LEVEL = 2` line and its comment:

```ruby
      # 3 — state revisions. Bumped IN THE SAME COMMIT that made the save door honour `state_id`,
      # per the rule above.
      #
      # NO CAPABILITY NAME CAME WITH IT, and that is the same decision recorded for binary output
      # below: revising is the SAME `library:write` door growing an optional parameter, so a
      # capability would be `true` exactly when `library:write` is and would carry no information.
      # `min_host: 3` is how a bundle requires it. `state:crud` stays false and reserved for the
      # direct PATCH/DELETE endpoints (docs/addon-api-v1.md §7.5), which this is not.
      LEVEL = 3
```

In `#states`, add the key:

```ruby
      render json: states.map { |s|
        { id: s.id, name: s.name, data: s.data, updated_at: s.updated_at, revision: s.revision,
          files: s.files.map { |f| { node_id: f.node_id, role: f.role } } }
      }
```

- [ ] **Step 4: Run**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb
```

Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/addons/host.rb app/controllers/tools/addons_controller.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): host level 3, and the states payload carries the revision number"
```

---

### Task 5: The revisions endpoint

**Files:**
- Modify: `config/routes.rb` (beside the existing `tools/:key/states` route)
- Modify: `app/controllers/tools/addons_controller.rb` (a `#revisions` action next to `#states`)
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
    # ---- the revision history --------------------------------------------------------------

    test "revisions are served newest first with their params" do
      state = save_box(name: "shelf box", params: { "h" => "60" })
      save_box(name: "shelf box", params: { "h" => "80" }, state_id: state.id)

      get tools_addon_state_revisions_path("widgetkit", state.id)
      assert_response :success
      body = response.parsed_body
      assert_equal [ 2, 1 ], body.map { |r| r["revision"] }
      assert_equal "80", body.first.dig("data", "params", "h")
      assert_equal "60", body.last.dig("data", "params", "h")
      assert body.first["created_at"].present?
    end

    test "another user's revisions are a 404" do
      other = User.create!(email: "other2@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "widgetkit", name: "not yours", data: {})
      get tools_addon_state_revisions_path("widgetkit", theirs.id)
      assert_response :not_found
    end

    test "revisions of a state in another addon's namespace are a 404" do
      foreign = @user.maker_addon_states.create!(addon_key: "someone-else", name: "theirs", data: {})
      get tools_addon_state_revisions_path("widgetkit", foreign.id)
      assert_response :not_found
    end
```

- [ ] **Step 2: Run and watch fail**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/revisions are served|another user's revisions|another addon's namespace are/"
```

Expected: `NameError: undefined local variable or method 'tools_addon_state_revisions_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, directly below the existing `get "tools/:key/states"` line:

```ruby
  # ONE saved state's revision history, newest first. FIVE segments, so unlike the two-segment
  # `tools/:key/states` above it has no ordering hazard with the `tools/:key` wildcard at all —
  # Rails requires a segment-count match, the same reason `tools/addon_states/:id/params` is safe.
  # It sits here to keep the addon surface in one block, not because the order protects it.
  #
  # LAZY BY DESIGN: the history is NOT inlined into the states list, because a 20-revision history
  # of 40-param snapshots across every saved box would bloat a gallery's first paint for data
  # nobody has expanded.
  get "tools/:key/states/:id/revisions", to: "tools/addons#revisions",
      as: :tools_addon_state_revisions
```

- [ ] **Step 4: Add the action**

In `app/controllers/tools/addons_controller.rb`, directly after `#states`:

```ruby
    # GET /tools/:key/states/:id/revisions — one saved state's history, newest first.
    #
    # SCOPED BY `states_key` AND `current_user`, exactly as #states is: the same data scope, so a
    # state this addon could not list is not a state whose history it can read. `find_by` + an
    # explicit 404 rather than `find`, so an unknown id and a stranger's id answer identically and
    # this endpoint cannot report whether a foreign state id exists.
    def revisions
      state = current_user.maker_addon_states.for_addon(@addon.states_key).find_by(id: params[:id])
      return head :not_found if state.nil?

      render json: state.revisions.reverse_order.map { |r|
        { revision: r.revision, data: r.data, created_at: r.created_at }
      }
    end
```

- [ ] **Step 5: Run**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/revisions/"
```

Expected: 0 failures.

- [ ] **Step 6: Verify the route does not shadow, or get shadowed by, `tools/:key`**

```bash
bin/rails runner 'r = Rails.application.routes; puts r.recognize_path("/tools/widgetkit/states/7/revisions"); puts r.recognize_path("/tools/widgetkit")'
```

Expected: the first prints `{controller: "tools/addons", action: "revisions", key: "widgetkit", id: "7"}`
and the second `{controller: "tools/addons", action: "show", key: "widgetkit"}`.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/tools/addons_controller.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): GET /tools/:key/states/:id/revisions serves a state's history"
```

---

### Task 6: The `?state=` deep link becomes `ctx.launch`

**Files:**
- Modify: `app/controllers/tools/addons_controller.rb` (`#addon_ctx`)
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
    # ---- the deep link ---------------------------------------------------------------------

    def launch_from_page
      JSON.parse(css_select("[data-addon-ctx-value]").first["data-addon-ctx-value"])["launch"]
    end

    test "a ?state= deep link is resolved into ctx.launch" do
      state = save_box(name: "shelf box")
      get tools_addon_path("widgetkit", state: state.id)
      assert_response :success
      assert_equal state.id, launch_from_page["stateId"]
    end

    test "no ?state= means a null stateId, not a missing key" do
      get tools_addon_path("widgetkit")
      assert_response :success
      assert launch_from_page.key?("stateId"), "the key must always be present"
      assert_nil launch_from_page["stateId"]
    end

    # SILENTLY IGNORED, NOT A 404. A stale bookmark or a deleted box must not take the tool down —
    # the id is a hint about which box to open, never an authorization decision.
    test "an unknown, foreign or other-addon ?state= renders the page with a null stateId" do
      other = User.create!(email: "other3@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "widgetkit", name: "not yours", data: {})
      foreign = @user.maker_addon_states.create!(addon_key: "someone-else", name: "theirs", data: {})

      [ 999_999, theirs.id, foreign.id, "not-a-number" ].each do |bad|
        get tools_addon_path("widgetkit", state: bad)
        assert_response :success, "?state=#{bad} must still render the tool"
        assert_nil launch_from_page["stateId"], "?state=#{bad} must not resolve"
      end
    end
```

- [ ] **Step 2: Run and watch fail**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/deep link|stateId/"
```

Expected: `NoMethodError: undefined method '[]' for nil` — `launch` is not in the ctx blob.

- [ ] **Step 3: Implement**

In `#addon_ctx`, add the key after `defaultFolder:`:

```ruby
        defaultFolder: { nodeId: @default_parent_node_id, label: @default_folder_label },
        # WHICH SAVED STATE THIS PAGE WAS OPENED FOR, from `?state=`. Resolved SERVER-SIDE so the
        # host validates ownership before the id reaches a bundle, and so the bundle never learns
        # the host's URL shape — the reason ctx exists at all.
        #
        # ALWAYS PRESENT, `stateId` nil when there is nothing to open. A missing key reads as
        # `undefined` in JS and cannot be told apart from a host that predates this, which is the
        # same argument Host::CAPABILITIES makes for every value being a real boolean.
        launch: { stateId: launch_state_id }
```

And in the private section, beside `#resolve_revision_target` (Task 2 shipped that name — an
earlier draft of this plan called it `#revision_target`, and the method that renders the 404 is its
sibling `#render_no_such_state`):

```ruby
    # THE `?state=` HINT, VALIDATED. Unknown, another user's, another addon's namespace, or plain
    # garbage all answer nil and the page renders normally — a stale bookmark or a deleted box must
    # never 404 the tool. Contrast #resolve_revision_target, whose caller DOES 404: there the id is
    # an instruction about where to write, and guessing wrong writes to the wrong place.
    def launch_state_id
      raw = params[:state]
      return nil if raw.blank?

      current_user.maker_addon_states.for_addon(@addon.states_key).find_by(id: raw)&.id
    end
```

**`blank?` here, deliberately, and it is the same contract Task 2 pins for `state_id`:** an empty
`?state=` is "no hint", not "a hint I could not resolve". Both spellings must stay `blank?`/`present?`
rather than a nil check — Task 2 has a mutation-checked test for its half; this half is cheap to get
right by copying it, and `""` reaching `find_by(id: "")` is the failure both avoid.

- [ ] **Step 4: Run**

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb
```

Expected: 0 failures.

- [ ] **Step 5: Mutation-check the ownership scope**

Change `current_user.maker_addon_states` to `Maker::AddonState` in `#launch_state_id`, then:

```bash
bin/rails test test/controllers/tools/addons_controller_test.rb -n "/unknown, foreign/"
```

Expected: **FAIL** on the foreign id. Restore.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/tools/addons_controller.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): ?state= resolves server-side into ctx.launch"
```

---

### Task 7: `Maker::AddonOrigin` — a library node back to the state that made it

**Files:**
- Create: `db/migrate/20260813000200_add_node_id_index_to_maker_addon_files.rb`
- Create: `app/services/maker/addon_origin.rb`
- Test: `test/services/maker/addon_origin_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/addon_origin_test.rb`:

```ruby
require "test_helper"

module Maker
  class AddonOriginTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "origin@example.com", password: "correct horse battery staple",
                           confirmed_at: Time.current)
      @state = @user.maker_addon_states.create!(addon_key: "boxes", name: "shelf box",
                                                data: {}, revision: 3)
      @state.files.create!(node_id: "node-a", role: "output", position: 0)
      @state.files.create!(node_id: "node-b", role: "output", position: 1)
    end

    test "resolves a node to the state that produced it" do
      origins = Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a node-zzz])
      assert_equal @state.id, origins["node-a"].state.id
      assert_equal "boxes", origins["node-a"].addon_key
      assert_equal "shelf box", origins["node-a"].state.name
    end

    # AN ABSENT KEY, NOT A RAISE AND NOT A NIL VALUE — the caller holds a page of node ids and most
    # of them will not be addon output. Same contract as the port's own stat_all (CLAUDE.md §14a).
    test "a node no addon produced is simply absent" do
      origins = Maker::AddonOrigin.for(user: @user, node_ids: %w[node-zzz])
      assert_empty origins
      assert_nil origins["node-zzz"]
    end

    test "another user's addon output is never resolved" do
      other = User.create!(email: "origin2@example.com", password: "correct horse battery staple",
                           confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "boxes", name: "theirs", data: {})
      theirs.files.create!(node_id: "node-theirs", role: "output", position: 0)

      assert_empty Maker::AddonOrigin.for(user: @user, node_ids: %w[node-theirs])
    end

    test "an empty node_ids list makes no query at all" do
      assert_equal 0, count_queries { Maker::AddonOrigin.for(user: @user, node_ids: []) }
    end

    # CONSTANT IN N, NOT A LITERAL. A per-node lookup here is an N+1 on a 2000-node library page,
    # and page_query_budget_test.rb asserts constancy for exactly that reason.
    test "the query count does not grow with the number of nodes" do
      10.times { |i| @state.files.create!(node_id: "bulk-#{i}", role: "output", position: 10 + i) }
      one = count_queries { Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a]) }
      many = count_queries do
        Maker::AddonOrigin.for(user: @user, node_ids: (0...10).map { "bulk-#{it}" } + %w[node-a])
      end
      assert_equal one, many
    end

    def count_queries(&block)
      count = 0
      counter = ->(_n, _s, _f, _i, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/services/maker/addon_origin_test.rb
```

Expected: `NameError: uninitialized constant Maker::AddonOrigin`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260813000200_add_node_id_index_to_maker_addon_files.rb`:

```ruby
# THE REVERSE DIRECTION. The existing [addon_state_id, node_id] composite answers "which files does
# this state own"; nothing indexed "which state produced this node", which is what the Files page
# asks for a whole page of nodes at once.
class AddNodeIdIndexToMakerAddonFiles < ActiveRecord::Migration[8.1]
  def change
    add_index :maker_addon_files, :node_id
  end
end
```

- [ ] **Step 4: Write the service**

Create `app/services/maker/addon_origin.rb`:

```ruby
module Maker
  # WHICH SAVED ADDON STATE PRODUCED A LIBRARY NODE — the reverse of Maker::AddonFile, resolved for
  # a whole page of nodes in ONE query.
  #
  # A MISSING NODE IS AN ABSENT KEY, NEVER A RAISE AND NEVER A nil VALUE. The caller holds a LIST
  # and most entries will not be addon output; the same contract the FileLayer port's `stat_all`
  # states for the same reason (CLAUDE.md §14a).
  #
  # THE QUERY COUNT MUST BE CONSTANT IN N. A per-node lookup is an N+1 on a 2000-node library page,
  # which `test/integration/web/page_query_budget_test.rb` asserts against.
  #
  # THIS CLASS DOES NOT KNOW WHICH ADDON PAGE TO OPEN. It answers with the state's `addon_key`,
  # which is a `states_key`; mapping that to a route needs the Registry, and the Registry is a
  # network call behind a cache that must not be made for a library with no addon output at all.
  # `.url_for` below is where that mapping lives, and it is only reachable once `for` found a hit.
  module AddonOrigin
    Origin = Data.define(:state, :addon_key)

    module_function

    # Returns { node_id => Origin }. Absent keys for nodes no addon produced.
    def for(user:, node_ids:)
      ids = Array(node_ids).compact.uniq
      return {} if ids.empty?

      Maker::AddonFile
        .joins("INNER JOIN maker_addon_states ON maker_addon_states.id = maker_addon_files.addon_state_id")
        .where(node_id: ids)
        .where(maker_addon_states: { user_id: user.id })
        .includes(:addon_state)
        .to_h { |f| [ f.node_id, Origin.new(state: f.addon_state, addon_key: f.addon_state.addon_key) ] }
    end
  end
end
```

Add the association `#includes(:addon_state)` needs — it already exists on `Maker::AddonFile`
(`belongs_to :addon_state`), so no model change.

- [ ] **Step 5: Migrate and run**

```bash
bin/rails db:migrate && bin/rails test test/services/maker/addon_origin_test.rb
```

Expected: 5 runs, 0 failures.

- [ ] **Step 6: Mutation-check the tenant scope**

Delete the `.where(maker_addon_states: { user_id: user.id })` line, then:

```bash
bin/rails test test/services/maker/addon_origin_test.rb -n "/another user/"
```

Expected: **FAIL**. Restore. (Unlike `Tools::AddonsController#file`, there is no adapter re-scoping
underneath this one — the scope here is the whole guard.)

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260813000200_add_node_id_index_to_maker_addon_files.rb db/schema.rb app/services/maker/addon_origin.rb test/services/maker/addon_origin_test.rb
git commit -m "feat(addons): resolve a library node back to the state that produced it"
```

---

### Task 8: The four surfaces

**Files:**
- Modify: `app/services/maker/addon_origin.rb` (add `.url_for`)
- Modify: `app/controllers/files_controller.rb` (`#index`, `#show`)
- Modify: `app/controllers/projects_controller.rb` (`#show`)
- Modify: `app/views/files/_list.html.erb`, `app/views/files/_grid.html.erb`, `app/views/projects/_attachment_group.html.erb`, `app/views/files/show.html.erb`
- Modify: `app/javascript/controllers/filemenu_controller.js`
- Test: `test/integration/web/page_query_budget_test.rb`, `test/system/file_menu_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/services/maker/addon_origin_test.rb`:

```ruby
    # THE states_key -> ROUTE MAPPING. Registry defaults states_key to key, so the normal case is
    # an exact match; the fallback exists only for a manifest that diverges, and nil is the honest
    # answer when no registered addon claims the key at all.
    #
    # RETURNS THE TITLE ALONGSIDE THE URL because the caller needs both and there is exactly one
    # place that knows which addon was chosen. An earlier draft returned the URL alone and had the
    # caller re-parse the key back out of it — one value derived from another by regex, which is the
    # drift shape this repo already carries scars from.
    ADDON = Struct.new(:key, :states_key, :title)

    test "link_for prefers the addon whose own key matches" do
      addons = [ ADDON.new("boxes-next", "boxes", "Boxes Next"), ADDON.new("boxes", "boxes", "Box Generator") ]
      assert_equal({ url: "/tools/boxes?state=#{@state.id}", title: "Box Generator" },
                   Maker::AddonOrigin.link_for(@state, addons:))
    end

    test "link_for falls back to an addon that declares the states_key" do
      addons = [ ADDON.new("boxes-next", "boxes", "Boxes Next") ]
      assert_equal({ url: "/tools/boxes-next?state=#{@state.id}", title: "Boxes Next" },
                   Maker::AddonOrigin.link_for(@state, addons:))
    end

    test "link_for is nil when no registered addon claims the key" do
      assert_nil Maker::AddonOrigin.link_for(@state, addons: [])
    end
```

Add to `test/integration/web/page_query_budget_test.rb`, inside `Web::PageQueryBudgetTest` and
following that file's own `assert_constant_queries` helper (read it first — it renders once to warm
lazy loads, then measures at `SMALL` and `LARGE`):

```ruby
    # THE REVERSE LOOKUP MUST NOT BE PER ROW. `Maker::AddonOrigin.for` resolves a whole page in one
    # query; written as a per-node lookup it is invisible on a 3-file fixture and fatal on a real
    # library. Constancy, never a literal — the counts differ per LIBRARY_BACKEND.
    test "files#index is constant in the number of addon-produced files" do
      assert_constant_queries "/files" do |n|
        state = @user.maker_addon_states.create!(addon_key: "boxes", name: "box #{n}", data: {})
        n.times do |i|
          node = seed_file("addon-#{n}-#{i}.svg")
          state.files.create!(node_id: node.node_id, role: "output", position: i)
        end
      end
    end
```

Use whatever the file's existing tests use to create a library node in place of `seed_file` — read
one of them and reuse its helper rather than adding a second way to seed a node.

- [ ] **Step 2: Run and watch fail**

```bash
bin/rails test test/services/maker/addon_origin_test.rb -n "/url_for/"
```

Expected: `NoMethodError: undefined method 'url_for' for module Maker::AddonOrigin`.

- [ ] **Step 3: Add `url_for`**

Append to `Maker::AddonOrigin`:

```ruby
    # THE ADDON PAGE THAT OPENS THIS STATE, as {url:, title:}, or nil. `addons` is Registry.all —
    # passed IN rather than fetched here so a caller resolving a page of nodes fetches the index
    # once, and so a library with no addon output never triggers the fetch at all (it is a network
    # call behind a 5-minute cache).
    #
    # BOTH VALUES COME BACK TOGETHER because the caller needs both and this is the one place that
    # knows which addon was chosen. Returning the URL alone and re-deriving the title from it is one
    # value parsed back out of another — the drift shape §14e records.
    #
    # PREFER AN EXACT `key` MATCH. Registry defaults states_key to key, so that is the normal case;
    # the states_key fallback covers a manifest that deliberately diverges. Where two addons share
    # a states_key this is a deterministic GUESS, not a fact — worst case it opens the sibling that
    # declared the shared key, which is a wrong page rather than a wrong write.
    def link_for(state, addons:)
      addon = addons.find { |a| a.key == state.addon_key } ||
              addons.find { |a| a.states_key == state.addon_key }
      return nil if addon.nil?

      { url: Rails.application.routes.url_helpers.tools_addon_path(addon.key, state: state.id),
        title: addon.title }
    end
```

- [ ] **Step 4: Wire the controllers**

Add this private helper to `app/controllers/files_controller.rb` and to
`app/controllers/projects_controller.rb` — or, preferably, extract it once into
`app/controllers/concerns/addon_origins.rb` and include it in both, since it is the same six lines:

```ruby
# THE "EDIT IN <ADDON>" LINK FOR A PAGE OF LIBRARY NODES. Two steps, deliberately in this order:
# the cheap indexed query first, and the Registry — a network call behind a cache — ONLY if that
# query found something. A library with no addon output must not make an addon page's outage into
# a slow Files page.
module AddonOrigins
  extend ActiveSupport::Concern

  private

  # Returns { node_id => { url:, title:, state: } }, absent keys for everything else.
  def addon_origins_for(node_ids)
    origins = Maker::AddonOrigin.for(user: current_user, node_ids:)
    return {} if origins.empty?

    addons = Maker::Addons::Registry.all
    origins.filter_map { |node_id, origin|
      link = Maker::AddonOrigin.link_for(origin.state, addons:)
      next if link.nil?

      [ node_id, link.merge(state: origin.state) ]
    }.to_h
  end
end
```

In `FilesController#index`, after `@nodes` is assigned in both branches (place it just before the
`respond_to`/render at the end so it covers flat and folder modes):

```ruby
    @addon_origins = addon_origins_for(@nodes.map(&:node_id))
```

In `FilesController#show`, after `@node` is loaded:

```ruby
    @addon_origins = addon_origins_for([ @node.node_id ])
```

In `ProjectsController#show`, after `@attachments` is assigned:

```ruby
    @addon_origins = addon_origins_for(@attachments.map(&:node_id))
```

And `include AddonOrigins` in all three controllers.

- [ ] **Step 5: Wire the views**

In `app/views/files/_list.html.erb`, `app/views/files/_grid.html.erb` and
`app/views/projects/_attachment_group.html.erb`, add one key to **every** `data:` hash that already
carries `note_url:` (there are two in `_list`, two in `_grid`, one in `_attachment_group`):

```erb
addon_open_url: @addon_origins.dig(node.node_id, :url),
```

Use `att.node_id` in the attachments partial. A nil value renders no attribute at all, which is
exactly how the menu opts out — the same mechanism `download_url` uses.

Above the first one in each file, add:

```erb
<%# data-addon-open-url puts "Edit in <Addon>" in the right-click menu (filemenu#open), for a file
    an addon produced. Absent for everything else, which is how a surface opts out — the same
    data-attribute mechanism download_url uses. %>
```

In `app/views/files/show.html.erb`, inside the `page-actions` div, before the Back link:

```erb
    <%# Reopens the generator with this file's saved parameters. Only for a file an addon actually
        produced — @addon_origins has no key for anything else. %>
    <% if (origin = @addon_origins[@node.node_id]) %>
      <%= link_to "Edit in #{origin[:title] || 'its generator'}", origin[:url], class: "btn ghost" %>
    <% end %>
```

And in the `<dl class="meta">`, after the Type row:

```erb
    <% if (origin = @addon_origins[@node.node_id]) %>
      <dt>Saved item</dt>
      <dd><%= link_to origin[:state].name, origin[:url] %> · v<%= origin[:state].revision %></dd>
    <% end %>
```

- [ ] **Step 6: Wire the menu entry**

In `app/javascript/controllers/filemenu_controller.js`, inside `open()`, after the Download block:

```javascript
    // "Edit in <Addon>" — only for a file an addon produced. Like every other entry here it is
    // built from a data- attribute the server wrote, so this controller cannot get the path shape
    // wrong and a surface without the attribute simply has no entry.
    const addonUrl = cell.dataset.addonOpenUrl
    if (addonUrl) {
      const edit = document.createElement("a")
      edit.href = addonUrl
      edit.textContent = cell.dataset.addonOpenLabel || "Edit in its generator"
      this.menu.appendChild(edit)
    }
```

Add `addon_open_label: @addon_origins.dig(node.node_id, :title)&.then { "Edit in #{it}" }` beside
each `addon_open_url:` so the entry names the addon.

- [ ] **Step 7: Run the suite**

```bash
bin/rails test
```

Expected: 0 failures. Then the system test for the menu:

```bash
bin/rails test:system TEST=test/system/file_menu_test.rb
```

- [ ] **Step 8: Pin, and mutation-check, the "no Registry call" rule**

Add to `test/controllers/files_controller_test.rb` (or the nearest existing Files integration test —
this must drive the real request, not the service):

```ruby
    # A LIBRARY WITH NO ADDON OUTPUT MUST NOT TOUCH THE ADDON SOURCE. Registry.all is a network
    # call behind a 5-minute cache; making the Files page depend on it would turn an addon-source
    # outage into a slow library for a user who has never opened /tools. The cheap indexed query
    # runs first and short-circuits.
    test "the files index does not consult the addon registry when nothing there came from an addon" do
      Maker::Addons::Source.stub = Class.new do
        def manifests = raise("the Files page must not fetch addon manifests")
        def asset(*) = raise("the Files page must not fetch addon assets")
      end.new

      get files_path
      assert_response :success
    ensure
      Maker::Addons::Source.reset!
    end
```

Run it, then mutation-check by moving `return {} if origins.empty?` in `#addon_origins_for` to
*below* the `Registry.all` line:

```bash
bin/rails test test/controllers/files_controller_test.rb -n "/does not consult the addon registry/"
```

Expected: **FAIL** with "the Files page must not fetch addon manifests". Restore the guard.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(files): reach a file's generator from the library, prefilled"
```

---

### Task 9: The SDK — `stateId`, `state.revisions`, `host.launch`

**Files:**
- Modify: `app/javascript/maker/addon_sdk.js:362-454` (`files.save`), `:533-546` (`state`)
- Test: `test/system/addon_sdk_test.rb`

- [ ] **Step 1: Teach the fixture bundle the three new calls**

`test/system/addon_sdk_test.rb` is hermetic — it drives `test/fixtures/addons/sdk-fixture/`, never
the sibling repo. Read that fixture first: every assertion below reads a `[data-role=…]` element the
fixture writes, so **the fixture is where the new calls are exercised from**.

Add to the fixture's entry module, alongside its existing controls:

```javascript
  // Revising: the same save, plus the id of the item it revises.
  el.querySelector("[data-role=sdk-save-revision]").addEventListener("click", async () => {
    const out = el.querySelector("[data-role=sdk-revision-out]")
    try {
      await host.files.save({
        name: "revised", folderNodeId: "", data: { n: 2 },
        stateId: Number(el.querySelector("[data-role=sdk-state-id]").value),
        files: [ { name: "revised.txt", contentType: "text/plain", body: "v2" } ],
      })
      out.textContent = "saved"
    } catch (e) { out.textContent = `${e.code}: ${e.message}` }
  })

  // The history, and the id guard in front of it.
  el.querySelector("[data-role=sdk-revisions]").addEventListener("click", async () => {
    const out = el.querySelector("[data-role=sdk-revisions-out]")
    try {
      const rows = await host.state.revisions(el.querySelector("[data-role=sdk-state-id]").value)
      out.textContent = rows.map((r) => `v${r.revision}`).join(",")
    } catch (e) { out.textContent = `${e.code}` }
  })

  // The deep-link hint, read straight through from ctx.
  el.querySelector("[data-role=sdk-launch]").textContent = `launch:${host.launch?.stateId ?? "none"}`
```

- [ ] **Step 1b: Write the failing browser tests**

```ruby
  test "files.save carries stateId through to the save door as a revision" do
    state = save_through_sdk_fixture   # reuse this file's existing save helper, or save via the door
    visit "/tools/sdk-fixture"
    fill_in_state_id(state.id)
    click_on "Save revision"
    assert_selector "[data-role=sdk-revision-out]", text: "saved"

    # ASSERTED ON WHAT THE SERVER RECORDED, never on the SDK's intent — the rule this file already
    # follows for service.post, and the only kind of assertion that can see a field the browser
    # dropped on the way out.
    assert_equal 2, state.reload.revision
    assert_equal [ 1, 2 ], state.revisions.pluck(:revision)
  end

  test "state.revisions reads the history newest first" do
    state = save_through_sdk_fixture
    visit "/tools/sdk-fixture"
    fill_in_state_id(state.id)
    click_on "Load revisions"
    assert_selector "[data-role=sdk-revisions-out]", text: "v1"
  end

  # REJECTED, NOT ENCODED. encodeURIComponent("..") is ".." verbatim, so the BROWSER normalises the
  # path before the request is sent and it never reaches the route the server guards — it misroutes
  # SILENTLY rather than being refused. Only a real browser can observe this, which is why it lives
  # here and not in a request test.
  test "state.revisions refuses a traversing state id before any request" do
    visit "/tools/sdk-fixture"
    [ "..", ".", "" ].each do |bad|
      fill_in_state_id(bad)
      click_on "Load revisions"
      assert_selector "[data-role=sdk-revisions-out]", text: "invalid_argument"
    end
  end

  test "host.launch carries the resolved deep link, and none is not an error" do
    state = save_through_sdk_fixture
    visit "/tools/sdk-fixture?state=#{state.id}"
    assert_selector "[data-role=sdk-launch]", text: "launch:#{state.id}"

    visit "/tools/sdk-fixture"
    assert_selector "[data-role=sdk-launch]", text: "launch:none"
    assert_no_console_errors
  end
```

Write `save_through_sdk_fixture` and `fill_in_state_id` as small helpers beside this file's existing
`install_sidecar`. The state must be created **through the real save door** so it has an `AddonFile`
row — a hand-built row has none, and the revision path would then have nothing to replace.

Also rename the existing test `"a min_host 1 manifest still mounts against a level 2 host"` to say
**level 3**. Its assertion derives from `Host::LEVEL` and stays green either way; the name is prose
that is now wrong.

- [ ] **Step 2: Run and watch fail**

```bash
bin/rails test:system TEST=test/system/addon_sdk_test.rb
```

- [ ] **Step 3: Implement**

In `files.save`, add `stateId = null` to the destructured options and, inside `build`:

```javascript
        // WHICH SAVED ITEM THIS SAVE REVISES. Omitted entirely when null, so a bundle that never
        // passes it sends byte-identical requests to what it always has. Requires host level 3;
        // an older host ignores the field and creates a new item, which is why a bundle that
        // depends on revising declares `min_host: 3` rather than feature-detecting a capability
        // (there is none — see Maker::Addons::Host::LEVEL).
        if (stateId !== null && stateId !== undefined) body.append("state_id", String(stateId))
```

In `state`, add beside `list`:

```javascript
    // One saved item's revision history, newest first. Lazy by design — the states list carries
    // only the current `revision` number, so a gallery pays nothing for histories nobody opened.
    revisions: async (id) => {
      this._require("state:list")
      const segment = encodeStateId(id)
      const res = await this._fetch(`${this._ctx.urls.states}/${segment}/revisions`,
                                    { headers: { Accept: "application/json" } })
      if (!res.ok) throw await errorFrom(res)
      try {
        return await res.json()
      } catch {
        throw new AddonError("invalid_response", "The host returned a non-JSON revision list.",
                             null, res.status)
      }
    },
```

And a module-level helper beside `encodeServiceName`:

```javascript
// REJECTED, NEVER NORMALIZED — the same rule as encodeServiceName. `encodeURIComponent("..")` is
// ".." verbatim, so the BROWSER resolves the path before the request is sent and it never reaches
// the route the server guards: it misroutes SILENTLY instead of being refused. Only ".", ".." and
// "" survive encoding; `/`, `#`, `?` and `%` need no clause.
function encodeStateId(id) {
  const s = String(id ?? "")
  if (s === "" || s === "." || s === "..") {
    throw new AddonError("invalid_argument", `"${s}" is not a usable state id.`)
  }
  return encodeURIComponent(s)
}
```

Add `launch` as a getter on the host class, reading `this._ctx.launch ?? { stateId: null }`.

- [ ] **Step 4: Run**

```bash
bin/rails test:system TEST=test/system/addon_sdk_test.rb
```

Expected: 0 failures.

- [ ] **Step 5: Mutation-check the id guard**

Change `encodeStateId` to `return encodeURIComponent(String(id))`, run the traversal test, confirm
**red**, restore.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/maker/addon_sdk.js test/system/addon_sdk_test.rb
git commit -m "feat(sdk): stateId on save, state.revisions, and host.launch"
```

---

### Task 10: The docs, in this branch

Per `CLAUDE.md` §15, `docs/STATUS.md` is part of the work and belongs in the same PR — deferred, it
does not happen.

**Files:**
- Modify: `CLAUDE.md` (§14c)
- Modify: `docs/STATUS.md`
- Modify: `docs/addon-api-v1.md`

- [ ] **Step 1: Add the invariants to `CLAUDE.md` §14c**

Add the six bullets listed verbatim in spec §12. Keep them one line each with the consequence
named, per §15's "Keeping the docs honest".

- [ ] **Step 2: Write the `docs/STATUS.md` entry**

One entry for the whole arc — amend it as later PRs land rather than appending a new one per PR.
Include the measured suite counts from Step 4 below and the dead-end this closed (spec §1.3).

- [ ] **Step 3: Update `docs/addon-api-v1.md`**

The author-facing contract: host level 3, `stateId` on save, the revisions endpoint, `host.launch`,
and the capability table's unchanged `state:crud` row with a note that revising is **not** it.

- [ ] **Step 4: Run all three legs and record the counts**

```bash
bin/ci
```

Expected: every gate green, and the three test legs reporting **identical** counts. Record those
counts in the STATUS entry.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/STATUS.md docs/addon-api-v1.md
git commit -m "docs: record the state-revision invariants and the arc"
```

---

## Done when

- `bin/ci` is green, all three test legs at identical counts.
- Every mutation check listed above has been performed and restored.
- The bundle repo has **not** been touched — that is the second plan, and it publishes only after
  this ships (spec §11).
