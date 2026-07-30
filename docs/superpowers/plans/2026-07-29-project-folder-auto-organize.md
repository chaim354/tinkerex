# Project folder auto-attach + auto-organize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A file that lands anywhere under `Projects/<slug>/` becomes an attachment on that project automatically, and a file sitting at that folder's **root** is filed into a lazily-created category subfolder (`cnc`, `laser`, `design`, `models`, `cad`, `docs`, `images`, `archives`, `other`).

**Architecture:** One service, `Maker::ProjectIntake`, reads `nodes` — the catalog all three backends populate — so it covers every write door (web upload, scan, device push, addon output, move, trash restore) without touching any of them. It reaches bytes only through the two existing cross-backend seams, `Maker::MoveNode` and `Maker::LibraryFolder`, so it adds **zero** new copies of the `port_writable?` branch. A recurring job runs it; on scanned backends it is called at the end of `Library::ScanJob#perform` so it can never overlap a scan.

**Tech Stack:** Rails 8, Minitest, SQLite (test/dev) / Postgres (managed), Solid Queue (`config/recurring.yml`).

**Spec:** `docs/superpowers/specs/2026-07-29-project-folder-auto-organize-design.md`

---

## Two deliberate departures from the spec

Both were found while mapping the plan onto the real code. They are here so they are not read as drift.

1. **The stale-role backfill is IN, as Task 2** — the spec put it out of scope on the grounds that "nothing here reads that column", which is true of the *folder* decision but not of the project panel's headings. Leaving `.lbrn2` attachment rows labelled "Vector" while their folder is `laser` is exactly the drift this design exists to prevent, and the repo already has the migration pattern twice over. **It is not a copy of either predecessor** — see the trap in Task 2.
2. **The dry run is `DRY_RUN=1`, not a `:dry_run` task** — the house idiom, set by `rake previews:reap_dead_nodes`. Surface-level, and consistency wins.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/models/maker/file_attachment.rb` (modify) | the ONE file-type vocabulary — gains a `laser` role and `nc`/`tap`/`ngc` |
| `db/migrate/*_rederive_laser_roles.rb` (create) | move existing `.lbrn2` attachment rows from `vector` to `laser` |
| `app/services/maker/project_folders.rb` (create) | role → subfolder name, plus the totality guard's constant |
| `app/services/maker/project_intake.rb` (create) | the whole policy: attach the subtree, file the root, the run cap |
| `app/jobs/maker/project_intake_job.rb` (create) | the chunk-mode schedule + the log wording |
| `app/jobs/library/scan_job.rb` (modify) | calls the intake inline, strictly after the reconcile |
| `app/controllers/files_controller.rb` (modify) | the eager nudge on both upload doors |
| `config/recurring.yml` (modify) | the chunk-mode schedule entry |
| `lib/tasks/projects.rake` (create) | `projects:organize`, cap lifted, `DRY_RUN=1` |

`ProjectFolders` is separate from `ProjectIntake` on purpose: the map is a piece of vocabulary that the totality test asks about directly, and the intake is a policy. Putting the map inside the service would make the guard test reach through a service to ask a question about a constant.

---

## Conventions used throughout

- **Run one test file:** `bin/rails test test/path/to/file.rb`
- **Run one test:** `bin/rails test test/path/to/file.rb -n test_the_name_with_underscores`
- **Pin a backend in a test:** `pin_file_layer_backend("chunk")` (helper in `test/test_helper.rb`; teardown restores it automatically)
- **Users have no fixtures** — create them inline: `User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current, omniauth_signup: true)`
- **Three-leg rule:** the suite must be green and identical on `bin/rails test`, `LIBRARY_BACKEND=share bin/rails test`, and `LIBRARY_BACKEND=s3 bin/rails test`. Task 13 does the full run; individual tasks run their own file only.
- **CI cannot run this.** Only the macOS runner is registered and all seven `ci.yml` jobs target linux, so they queue forever rather than failing. Verification is local.

---

## Task 1: The `laser` role and the CNC extensions

**Files:**
- Modify: `app/models/maker/file_attachment.rb:11-50`
- Test: `test/models/maker/file_attachment_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside the existing `class FileAttachmentTest` in `test/models/maker/file_attachment_test.rb`:

```ruby
  # THE SPLIT THE FOLDER MAP NEEDS. svg/dxf/lbrn2 were all `vector`, so "laser" and "design" were
  # not distinguishable in the one place the app defines file types.
  test "lbrn2 is laser, not vector" do
    assert_equal "laser", Maker::FileAttachment.role_for("box.lbrn2")
  end

  test "svg and dxf stay vector" do
    assert_equal "vector", Maker::FileAttachment.role_for("panel.svg")
    assert_equal "vector", Maker::FileAttachment.role_for("panel.dxf")
  end

  # These had NO role at all before — a CNC-heavy project was entirely "Other".
  test "nc, tap and ngc are gcode" do
    %w[nc tap ngc].each do |ext|
      assert_equal "gcode", Maker::FileAttachment.role_for("part.#{ext}"), ext
    end
  end

  test "laser is a real role, so the inclusion validation accepts it" do
    assert_includes Maker::FileAttachment::ROLES, "laser"
    assert_equal "Laser", Maker::FileAttachment::ROLE_LABELS["laser"]
  end

  # Every extension must satisfy FilesController::EXT_RE or it renders a filter chip that links and
  # silently does nothing. The three new ones are short, but the rule is what matters.
  test "every extension satisfies the Files-page filter regex" do
    Maker::FileAttachment::ROLE_BY_EXT.each_key do |ext|
      assert_match FilesController::EXT_RE, ext, ext
    end
  end

  # pdf must NOT drift to `document`: Models::AttachmentsController dispatches
  # ExtractPdfMetadataJob on this exact value, so the column is behavioural.
  test "pdf is still instructions" do
    assert_equal "instructions", Maker::FileAttachment.role_for("guide.pdf")
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/models/maker/file_attachment_test.rb
```

Expected: FAIL. `lbrn2 is laser` fails with `Expected: "laser" Actual: "vector"`; `nc, tap and ngc` fails with `Expected: "gcode" Actual: "other"`; `laser is a real role` fails on `assert_includes`.

- [ ] **Step 3: Add the role and the extensions**

In `app/models/maker/file_attachment.rb`, insert `"laser"` into `ROLE_LABELS` **immediately after `"vector"`** — this hash is display order for the project panel and the Files-page chips, so laser belongs beside the vector work it was split out of:

```ruby
    ROLE_LABELS = {
      "model"          => "Models",
      "image"          => "Images",
      "instructions"   => "Instructions",
      "document"       => "Documents",
      "vector"         => "Vector",
      "laser"          => "Laser",
      "cad_source"     => "CAD source",
      "gcode"          => "G-code",
      "source_archive" => "Archives",
      "other"          => "Other"
    }.freeze
```

Then change the two relevant lines of `ROLE_BY_EXT`. The gcode line:

```ruby
      "pdf" => "instructions", "zip" => "source_archive",
      # CNC. `nc`/`tap`/`ngc` are the router/mill dialects; without them a CNC-heavy project is
      # entirely "Other". They join `gcode` rather than getting a role of their own because they
      # ARE g-code — the folder split (cnc vs laser) is Maker::ProjectFolders' job, not a reason to
      # fragment the vocabulary.
      "gcode" => "gcode", "gco" => "gcode", "nc" => "gcode", "tap" => "gcode", "ngc" => "gcode",
```

and the vector line:

```ruby
      # Laser / 2D vector work. `lbrn2` is LASER, not vector: a LightBurn document is a machine
      # program, while svg/dxf are drawings you might cut on anything. That distinction is what
      # lets Maker::ProjectFolders put them in different folders — and the ONE vocabulary is where
      # it has to live, or the panel headings and the folders disagree.
      "svg" => "vector", "dxf" => "vector", "lbrn2" => "laser",
```

Note the `"zip" => "source_archive"` moved onto the `pdf` line because the old line bundled `pdf`, `gcode`, `gco` and `zip` together; keep every pair, just regrouped.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/models/maker/file_attachment_test.rb test/helpers/files_helper_test.rb
```

Expected: PASS, both files. `files_helper_test.rb` is included because `FilesHelper::EXT_FAMILIES` *derives* from these two constants — it should gain a "Laser" family and three g-code extensions with **no change to the helper or its test**. If a helper test fails, the derivation was broken, not the data.

- [ ] **Step 5: Commit**

```bash
git add app/models/maker/file_attachment.rb test/models/maker/file_attachment_test.rb
git commit -m "feat(vocabulary): a laser role, and CNC extensions that had none

lbrn2 moves vector -> laser and nc/tap/ngc join gcode, in ROLE_BY_EXT — the
ONE file-type vocabulary. FilesHelper::EXT_FAMILIES derives from it, so the
Files-page chips and the project panel headings follow with no second edit.

The split exists because Maker::ProjectFolders needs to put a LightBurn
document (a machine program) somewhere other than an svg (a drawing), and
the place that distinction can live without drifting is here."
```

---

## Task 2: Backfill existing `.lbrn2` attachment rows

**Files:**
- Create: `db/migrate/<timestamp>_rederive_laser_roles.rb`
- Test: `test/models/maker/rederive_laser_roles_migration_test.rb`

**Read this before writing it.** There are two predecessors — `20260728124303_rederive_vector_and_cad_source_roles.rb` and `20260729035422_rederive_document_roles.rb` — and **copying either one produces a migration that does nothing and a rollback that makes things worse.** Both predecessors added *brand-new* extensions, so every affected row was sitting in `other`; they select `where(role: "other")` and their `down` returns rows to `"other"`. This migration is a different shape: `lbrn2` already had a role. So:

- `up` must select **`where(role: "vector")`**, not `"other"`. Selecting `other` finds nothing and the migration silently succeeds having changed zero rows.
- `down` must return laser rows to **`"vector"`**, not `"other"`. Sending them to `other` would leave them *worse off than before the migration ran*.

**Task 1 left one test RED, on purpose, and closing it is this task's Step 0.** `test/models/maker/rederive_roles_migration_test.rb` has a tripwire — *"The migration deliberately COPIES its extension list rather than referencing ROLE_BY_EXT, so the two can silently drift. This is the only thing that would notice."* — asserting the 2026-07-28 migration's frozen `NEW_ROLE_BY_EXT` still agrees with the live model. Task 1 remapped `lbrn2`, so it fires with `migration maps lbrn2 to vector, model disagrees`.

**That is the tripwire working, not a defect.** It exists to make someone stop and decide, and the decision is: the old migration's frozen copy stays frozen (rewriting a shipped migration's snapshot is what its own header forbids), and `RederiveLaserRoles` — created below — is what carries `lbrn2` forward. What must change is the *tripwire*, so it records the deliberate divergence without going blind to the next accidental one.

- [ ] **Step 0: Narrow the tripwire to the one deliberate divergence**

Replace the tripwire test at the end of `test/models/maker/rederive_roles_migration_test.rb`:

```ruby
  # The migration deliberately COPIES its extension list rather than referencing ROLE_BY_EXT, so the
  # two can silently drift. This is the only thing that would notice.
  #
  # ONE EXTENSION IS ALLOWED TO DISAGREE, and it is listed rather than skipped. `lbrn2` was remapped
  # `vector` -> `laser` when the laser role was added; this migration's snapshot stays frozen (its
  # own header forbids rewriting it — it must run against whatever the code looks like months from
  # now), and RederiveLaserRoles is what carries those rows forward instead.
  #
  # THE SECOND ASSERTION IS WHAT STOPS THE EXCEPTION OUTLIVING ITS CAUSE. Without it, an entry here
  # would silently stay valid forever — including after someone remapped lbrn2 back — and the
  # allowlist would quietly become the drift it exists to catch.
  SUPERSEDED = { "lbrn2" => "laser" }.freeze

  test "the migration's extension list still agrees with the model's" do
    RederiveVectorAndCadSourceRoles::NEW_ROLE_BY_EXT.each do |ext, role|
      next if SUPERSEDED.key?(ext)

      assert_equal role, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "migration maps #{ext} to #{role}, model disagrees"
    end
  end

  test "every superseded extension really is superseded" do
    SUPERSEDED.each do |ext, role|
      assert_equal role, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "#{ext} is listed as superseded to #{role}, but the model says " \
                   "#{Maker::FileAttachment::ROLE_BY_EXT[ext].inspect} — remove it from SUPERSEDED"
      assert_not_equal role, RederiveVectorAndCadSourceRoles::NEW_ROLE_BY_EXT[ext],
                       "#{ext} no longer disagrees with the old migration — remove it from SUPERSEDED"
    end
  end
```

Run it:

```bash
bin/rails test test/models/maker/rederive_roles_migration_test.rb
```

Expected: PASS. Then **mutation-check the allowlist**: temporarily add `"svg" => "vector"` to `SUPERSEDED` and re-run — expected FAIL on `every superseded extension really is superseded` (svg agrees with the old migration, so it is not superseded). **Remove the line** and confirm green again.

- [ ] **Step 1: Generate the migration file**

```bash
bin/rails generate migration RederiveLaserRoles
```

Note the generated path — the timestamp is yours; the rest of this task calls it `db/migrate/<timestamp>_rederive_laser_roles.rb`.

- [ ] **Step 2: Write the failing test**

Create `test/models/maker/rederive_laser_roles_migration_test.rb`:

```ruby
require "test_helper"
require Dir[Rails.root.join("db/migrate/*_rederive_laser_roles.rb")].first

# Drives the migration's up AND down against real rows rather than trusting it by reading.
#
# THIS MIGRATION IS NOT ITS PREDECESSORS. Both earlier rederive migrations moved rows OUT OF
# "other" (they added new extensions), so they select role: "other" and their `down` returns rows
# to "other". lbrn2 already had a role, so this one moves vector -> laser and must roll back to
# vector. Copying a predecessor gives a no-op `up` and a `down` that puts the rows somewhere worse
# than where they started, and neither failure is visible without driving it.
class RederiveLaserRolesMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rederive-laser-#{SecureRandom.hex(4)}@example.com",
                         confirmed_at: Time.current, omniauth_signup: true)
    @project = @user.maker_projects.create!(name: "Lamp")
  end

  # node_id has no FK — the filename lives on the node, so the migration has to join to find it.
  def attach(name, role)
    node_id = "n-#{name}-#{SecureRandom.hex(2)}"
    @user.nodes.create!(node_id:, name:, kind: "file")
    @project.file_attachments.create!(user: @user, node_id:, role:)
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { RederiveLaserRoles.new.up }
  end

  def run_rollback
    ActiveRecord::Migration.suppress_messages { RederiveLaserRoles.new.down }
  end

  test "a vector row pointing at a lbrn2 file becomes laser" do
    att = attach("box.lbrn2", "vector")
    run_migration
    assert_equal "laser", att.reload.role
  end

  # THE HALF A COPIED PREDECESSOR GETS WRONG. Selecting role: "other" finds nothing at all.
  test "it looks in vector, not other" do
    att = attach("tray.lbrn2", "vector")
    run_migration
    assert_equal "laser", att.reload.role,
                 "the migration must select role: 'vector' — lbrn2 already had a role"
  end

  test "svg and dxf rows are left alone" do
    svg = attach("panel.svg", "vector")
    dxf = attach("panel.dxf", "vector")
    run_migration
    assert_equal "vector", svg.reload.role
    assert_equal "vector", dxf.reload.role
  end

  test "a row whose node is gone is skipped, not crashed on" do
    att = @project.file_attachments.create!(user: @user, node_id: "ghost", role: "vector")
    assert_nothing_raised { run_migration }
    assert_equal "vector", att.reload.role
  end

  # THE OTHER HALF. A copied `down` sends these to "other" — worse than where they started.
  test "down returns laser rows to vector" do
    att = attach("case.lbrn2", "vector")
    run_migration
    run_rollback
    assert_equal "vector", att.reload.role
  end

  test "up is idempotent" do
    att = attach("lid.lbrn2", "vector")
    run_migration
    run_migration
    assert_equal "laser", att.reload.role
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rails test test/models/maker/rederive_laser_roles_migration_test.rb
```

Expected: FAIL with `NameError: uninitialized constant RederiveLaserRoles` — the generated migration is still an empty class body, so `up`/`down` do nothing. (If it resolves but every test fails on the role value, that is the same starting point.)

- [ ] **Step 4: Write the migration**

Replace the generated file's contents:

```ruby
# Moves attachments that were `vector` only because ROLE_BY_EXT had no `laser` role into the one
# added alongside this migration.
#
# SELF-CONTAINED ON PURPOSE, as both predecessors are
# (20260728124303_rederive_vector_and_cad_source_roles.rb,
# 20260729035422_rederive_document_roles.rb). It does not call Maker::FileAttachment.role_for and
# does not use the app's models: a data migration runs against whatever the schema and the code look
# like months from now, and app code keeps moving.
#
# IT IS NOT A COPY OF EITHER PREDECESSOR, AND THE DIFFERENCE IS THE WHOLE MIGRATION. Both of those
# added BRAND-NEW extensions, so every row they had to fix was sitting in "other" — they select
# `role: "other"` and their `down` returns rows to "other". `lbrn2` already HAD a role. So:
#
#   * `up` selects `role: "vector"`. Selecting "other" would find nothing and succeed silently.
#   * `down` returns to "vector". Returning to "other" would leave these rows WORSE OFF than
#     before this migration ran — a rollback that loses information the forward migration had.
#
# Both halves are pinned by test/models/maker/rederive_laser_roles_migration_test.rb, because
# neither failure is visible from reading it next to its predecessors.
class RederiveLaserRoles < ActiveRecord::Migration[8.1]
  # The extensions that moved INTO `laser`. A COPY rather than a reference, for the predecessors'
  # stated reason — and with the same accepted cost: an extension added to the model after this runs
  # never re-derives the rows already sitting in `vector`, and closing that needs another migration.
  LASER_EXTS = %w[lbrn2].freeze

  # Where they came FROM. Named rather than inlined because `down` needs the same value, and the two
  # being one constant is what stops a rollback sending rows somewhere they were never.
  PRIOR_ROLE = "vector".freeze
  NEW_ROLE = "laser".freeze

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    moved = 0
    MigrationAttachment.where(role: PRIOR_ROLE).find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil? # attachment to a deleted/missing node — nothing to derive from
      ext = File.extname(node.name.to_s).downcase.delete(".")
      next unless LASER_EXTS.include?(ext)
      att.update_columns(role: NEW_ROLE)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  # Returns EVERY laser row to `vector`, not only the rows `up` moved — it has no record of which
  # those were, and `role_for` is already live in four controllers, so organic `laser` rows can
  # exist before `up` ever runs. Acceptable for the predecessors' reason: the pair is self-healing,
  # since the mapping is a pure function of the current filename.
  def down
    MigrationAttachment.where(role: NEW_ROLE).update_all(role: PRIOR_ROLE)
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/models/maker/rederive_laser_roles_migration_test.rb
```

Expected: PASS, 6 tests.

- [ ] **Step 6: Migrate the local dev DB and commit**

```bash
bin/rails db:migrate
git add db/migrate db/schema.rb test/models/maker/rederive_laser_roles_migration_test.rb
git commit -m "fix(roles): backfill existing lbrn2 attachments to the laser role

Task 1 split lbrn2 out of vector; existing rows still say vector, so the
project panel would head them 'Vector' while their folder is 'laser' — the
drift this design exists to prevent.

NOT a copy of the two predecessor rederive migrations, and the difference is
the whole migration: both of those moved rows out of 'other' (they added new
extensions), so they select role: 'other' and roll back to 'other'. lbrn2
already had a role. Selecting 'other' here finds nothing and succeeds
silently; rolling back to 'other' leaves the rows worse off than before. Both
halves are driven by a test rather than reasoned about."
```

---

## Task 3: `Maker::ProjectFolders`

**Files:**
- Create: `app/services/maker/project_folders.rb`
- Test: `test/services/maker/project_folders_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/project_folders_test.rb`:

```ruby
require "test_helper"

module Maker
  # The folder map, and above all its TOTALITY.
  class ProjectFoldersTest < ActiveSupport::TestCase
    # THE GUARD THIS FILE EXISTS FOR. `folder_for` uses `fetch` with no default, so a role with no
    # folder raises — but role_for only ever answers a member of ROLES, so that raise is
    # unreachable in practice and this test is the only thing that can catch the gap. A role added
    # to the vocabulary without a folder decision is a file that is never filed: no error, no log,
    # no node moved. Mutation-check it by deleting a key from ROLE_FOLDERS.
    test "every role has a folder" do
      assert_equal Maker::FileAttachment::ROLES.to_set,
                   Maker::ProjectFolders::ROLE_FOLDERS.keys.to_set,
                   "add the new role to ROLE_FOLDERS — a role with no folder is never filed"
    end

    test "the categories the folders were named for" do
      assert_equal "cnc",      Maker::ProjectFolders.folder_for("pocket.nc")
      assert_equal "cnc",      Maker::ProjectFolders.folder_for("roughing.gcode")
      assert_equal "laser",    Maker::ProjectFolders.folder_for("box.lbrn2")
      assert_equal "design",   Maker::ProjectFolders.folder_for("panel.svg")
      assert_equal "design",   Maker::ProjectFolders.folder_for("panel.dxf")
      assert_equal "models",   Maker::ProjectFolders.folder_for("bracket.stl")
      assert_equal "cad",      Maker::ProjectFolders.folder_for("body.f3d")
      assert_equal "docs",     Maker::ProjectFolders.folder_for("guide.pdf")
      assert_equal "docs",     Maker::ProjectFolders.folder_for("notes.md")
      assert_equal "images",   Maker::ProjectFolders.folder_for("photo.jpg")
      assert_equal "archives", Maker::ProjectFolders.folder_for("printables.zip")
    end

    # An unrecognised extension must land somewhere rather than raise: role_for defaults to
    # "other", so this is really asserting the two defaults agree.
    test "an unknown extension goes to other" do
      assert_equal "other", Maker::ProjectFolders.folder_for("mystery.qqq")
      assert_equal "other", Maker::ProjectFolders.folder_for("README")
    end

    # The names are lowercase because they appear in Finder and on the NAS. NOT asserted against
    # NAMES, which was removed as speculative: nothing consumed it, and its presence nudged a
    # reader toward pre-creating all nine folders — the opposite of the lazy creation Task 5 needs.
    test "folder names are single lowercase path segments" do
      Maker::ProjectFolders::ROLE_FOLDERS.values.uniq.each do |name|
        assert_match(/\A[a-z0-9]+\z/, name, name)
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/maker/project_folders_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Maker::ProjectFolders`.

- [ ] **Step 3: Write the module**

Create `app/services/maker/project_folders.rb`:

```ruby
module Maker
  # Which subfolder of `Projects/<slug>/` a file belongs in.
  #
  # DERIVED FROM THE ONE VOCABULARY, not a second extension table beside it. The key is a
  # Maker::FileAttachment ROLE, and the lookup goes through `role_for`, so adding an extension is
  # still a one-line edit to ROLE_BY_EXT and nothing here has to hear about it. A hand-written
  # ext => folder hash is the exact drift `FilesHelper::EXT_FAMILIES` was rewritten to end
  # (2026-07-29): two independent lists that disagreed about `.svg` for months.
  #
  # THE ANSWER COMES FROM THE FILENAME, NEVER FROM A STORED `role` COLUMN. An attachment row's role
  # is a snapshot taken when the row was written; a file can be swept before any row exists, and a
  # stale row would misfile it. `role_for` is pure and current.
  #
  # `fetch` WITH NO DEFAULT IS THE GUARD, and it is unreachable on purpose. `role_for` only ever
  # answers a member of ROLES (it fetches with an "other" default), so a raise here cannot happen
  # from real input — which is precisely why the totality test in
  # test/services/maker/project_folders_test.rb is the only thing that can catch a role added
  # without a folder. Silence is the failure mode being guarded: an unmapped role would be a file
  # that is never filed, with no error, no log and no node moved. A `fetch(..., "other")` default
  # would turn that into a wrong answer nobody could see.
  #
  # THE NAMES ARE LOWERCASE AND ARE NOT ROLE_LABELS. These strings become real directories in the
  # user's Finder and on their NAS, where `cnc` reads better than `G-code`. ROLE_LABELS are UI
  # headings; the one place they win here is `archives`, which has no better plain-language name.
  module ProjectFolders
    ROLE_FOLDERS = {
      "gcode"          => "cnc",
      "laser"          => "laser",
      "vector"         => "design",
      "model"          => "models",
      "cad_source"     => "cad",
      "instructions"   => "docs",
      "document"       => "docs",
      "image"          => "images",
      "source_archive" => "archives",
      "other"          => "other"
    }.freeze

    module_function

    def folder_for(name)
      ROLE_FOLDERS.fetch(Maker::FileAttachment.role_for(name))
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/maker/project_folders_test.rb
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Mutation-check the guard**

Temporarily delete the `"laser" => "laser",` line from `ROLE_FOLDERS`, then:

```bash
bin/rails test test/services/maker/project_folders_test.rb -n test_every_role_has_a_folder
```

Expected: FAIL. Then **restore the line** and re-run the whole file to confirm PASS. A guard that stays green when broken is not a guard.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/project_folders.rb test/services/maker/project_folders_test.rb
git commit -m "feat(projects): the role -> subfolder map, total over ROLES

Keyed on a FileAttachment role and looked up through role_for, so adding an
extension stays a one-line edit to the one vocabulary. fetch with no default
plus a totality test is the guard: a role added without a folder is a file
that is never filed — no error, no log, no node moved — so silence is the
failure mode, and a fetch default would only hide it. Mutation-checked."
```

---

## Task 4: `ProjectIntake` — the attach step

**Files:**
- Create: `app/services/maker/project_intake.rb`
- Test: `test/services/maker/project_intake_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/project_intake_test.rb`:

```ruby
require "test_helper"

module Maker
  # The intake policy, WITHOUT HTTP.
  #
  # PINNED TO CHUNK, like attach_to_project_test.rb, and for the same reason: the policy is
  # backend-neutral, but the move it drives is Maker::MoveNode's two-door branch and on share/s3
  # the port wants a real disk or bucket behind every fixture. The doors themselves are covered
  # per-backend in move_node_test.rb and library_folder_test.rb.
  class ProjectIntakeTest < ActiveSupport::TestCase
    setup do
      pin_file_layer_backend("chunk")
      @user = User.create!(email: "pi-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
    end

    # A live file node under `parent`, defaulting to the project folder's root (the inbox).
    def file(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                          parent_node_id: parent, size: 1, content_hash: SecureRandom.hex(8))
    end

    def dir(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent)
    end

    def intake = Maker::ProjectIntake.for_project(user: @user, project: @project)

    def roles = @project.file_attachments.pluck(:node_id, :role).to_h

    # --- the attach step ---------------------------------------------------------

    test "a file at the project folder root is attached" do
      node = file("bracket.stl")
      result = intake
      assert_equal 1, result.attached
      assert_equal "model", roles[node.node_id]
    end

    # THE HEADLINE CASE: dropped straight into a subfolder on the NAS, never at the root.
    test "a file nested in a subfolder is attached too" do
      sub = dir("design")
      node = file("panel.svg", parent: sub.node_id)
      assert_equal 1, intake.attached
      assert_equal "vector", roles[node.node_id]
    end

    test "a file two levels down is attached" do
      deep = dir("wip", parent: dir("design").node_id)
      node = file("draft.dxf", parent: deep.node_id)
      assert_equal 1, intake.attached
      assert_includes roles.keys, node.node_id
    end

    test "a file outside the project folder is not attached" do
      file("stray.stl", parent: nil)
      assert_equal 0, intake.attached
      assert_empty roles
    end

    test "a tombstoned file is not attached" do
      node = file("gone.stl")
      node.update!(deleted: true)
      assert_equal 0, intake.attached
    end

    test "directories are never attached" do
      dir("design")
      assert_equal 0, intake.attached
    end

    test "attaching is idempotent — a second run creates nothing" do
      file("bracket.stl")
      assert_equal 1, intake.attached
      assert_equal 0, intake.attached
      assert_equal 1, @project.file_attachments.count
    end

    # The row this service would have created already exists, made by the ordinary attach flow.
    test "a file already attached is not attached twice" do
      node = file("bracket.stl")
      @project.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      assert_equal 0, intake.attached
      assert_equal 1, @project.file_attachments.count
    end

    test "the role is derived per file, not copied" do
      stl = file("bracket.stl")
      pdf = file("guide.pdf")
      lbrn = file("box.lbrn2")
      intake
      assert_equal "model", roles[stl.node_id]
      assert_equal "instructions", roles[pdf.node_id]
      assert_equal "laser", roles[lbrn.node_id]
    end

    # --- the folder is READ, never ensured ---------------------------------------

    # THE SIDE-EFFECT BUG THIS DESIGN IS WRITTEN TO AVOID. Projects::AttachmentsController#relocate
    # shipped exactly this: an endpoint that created Projects/<slug> as a side effect of being
    # asked a question. A SWEEP doing it would create a folder for every project that never had one.
    test "a project with no folder is skipped and no folder is created" do
      bare = @user.maker_projects.create!(name: "Nothing Yet")
      before = @user.nodes.count
      result = Maker::ProjectIntake.for_project(user: @user, project: bare)
      assert_equal :no_folder, result.status
      assert_equal 0, result.attached
      assert_equal before, @user.nodes.count, "a sweep must not create the project's folder"
      assert_nil bare.reload.folder_node_id
    end

    test "a project whose folder was deleted is skipped, not recreated" do
      @folder.update!(deleted: true)
      before = @user.nodes.present.count
      assert_equal :no_folder, intake.status
      assert_equal before, @user.nodes.present.count
    end

    # An archived project's folder is still its folder. Skipping it would let files pile up in it
    # permanently unattached, silently.
    test "an archived project is still swept" do
      @project.archive!
      file("bracket.stl")
      assert_equal 1, intake.attached
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Maker::ProjectIntake`.

- [ ] **Step 3: Write the service with the attach step only**

Create `app/services/maker/project_intake.rb`:

```ruby
module Maker
  # Make the catalog agree with what is in a project's library folder: attach every file under it,
  # and file whatever is loose at its root into a category subfolder.
  #
  # WHY A SWEEP RATHER THAN A HOOK ON EVERY WRITE. A file can reach `Projects/<slug>/` six ways —
  # FilesController#create (share/s3), #finalize_upload (chunk), Library::Reconciler (the scan),
  # Sync::Commit#finalize (a device push), Maker::Addons::LibraryOutput, Maker::MoveNode, and a
  # trash restore. There is no single funnel. Hooking each is six sites that must agree, and a
  # SEVENTH door silently skips the rule — the failure this repo has recorded more than once
  # (Maker::AttachToProject's header; the five port_writable? copies; the four instances of the
  # Scanner's skip-list blind spot, each found only after the previous explanation said it could not
  # happen). This reads `nodes`, the catalog ALL THREE BACKENDS populate, so it covers every door
  # and any future one without touching any of them.
  #
  # IT ADDS NO NEW COPY OF THE port_writable? BRANCH. Maker::MoveNode owns the move and
  # Maker::LibraryFolder owns the mkdir; both already branch correctly for this deployment.
  #
  # §10 BOUNDARY: maker-layer policy. It reaches bytes only through those two services, and nothing
  # here touches Sync::*, the changelog, conflicts, locks or the mounts.
  class ProjectIntake
    # What one project's intake did. `plan` is filled only in a dry run — [name, folder] pairs, so
    # the rake task can print source -> destination without a second traversal.
    Result = Data.define(:attached, :moved, :skipped, :plan, :status)

    # How deep the tree walks go before giving up. A project folder is shallow; this is a backstop
    # against a CYCLE in `nodes`, which makes an unbounded walk spin — fatal on SQLite, which has
    # no statement timeout (the same hazard V1::NodesController#move spends would_create_cycle? on).
    MAX_DEPTH = 32

    def self.for_project(user:, project:, dry_run: false, move: true)
      new(user:, project:, dry_run:, move:).call
    end

    def initialize(user:, project:, dry_run: false, move: true)
      @user = user
      @project = project
      @dry_run = dry_run
      @move = move
    end

    def call
      folder = live_folder
      return Result.new(attached: 0, moved: 0, skipped: 0, plan: [], status: :no_folder) unless folder

      files = subtree_files(folder)
      attached = attach(files)

      Result.new(attached:, moved: 0, skipped: 0, plan: [], status: :ok)
    end

    private

    # READ, never Project#ensure_library_folder!.
    #
    # NOT AN OPTIMIZATION. Calling the ensure would make a SWEEP create `Projects/<slug>` for every
    # project that never had one, as a side effect of looking — which is the bug
    # Projects::AttachmentsController#relocate shipped ("the endpoint created Projects/<slug> as a
    # side effect of being POSTed to"), at library scale. The MoveConflicts concern reads rather
    # than calls for the same reason.
    def live_folder
      return nil if @project.folder_node_id.blank?
      @user.nodes.present.find_by(node_id: @project.folder_node_id, kind: "dir")
    end

    # Every live FILE in the folder's subtree, breadth-first — ONE QUERY PER LEVEL, not per node.
    #
    # A `dir` is descended into and a `file` is collected; a SYMLINK is neither, so it is ignored
    # rather than enqueued as a parent it cannot be. The visited set makes a cycle terminate instead
    # of spinning (see MAX_DEPTH), and it is checked before the kind so a cycle through a directory
    # cannot re-enqueue it.
    def subtree_files(folder)
      files = []
      frontier = [ folder.node_id ]
      seen = Set.new(frontier)
      MAX_DEPTH.times do
        break if frontier.empty?
        children = @user.nodes.present.where(parent_node_id: frontier).to_a
        frontier = []
        children.each do |node|
          next unless seen.add?(node.node_id)
          if node.file?
            files << node
          elsif node.dir?
            frontier << node.node_id
          end
        end
      end
      files
    end

    # Create the missing attachment rows in ONE statement.
    #
    # Bulk, not one SELECT + one INSERT per file, for the reason Maker::AttachToProject#attach_bundle
    # records: that loop cost 2 queries per file and ran inside a write transaction, so on the
    # SQLite self-host deployment the write lock was taken at the first INSERT and held to COMMIT —
    # one attach stalled every other writer in the app. A sweep is strictly larger than a bundle.
    #
    # insert_all SKIPS VALIDATIONS, so what they protected holds by construction, exactly as it does
    # there: role_for answers a member of ROLES for ANY input, node_id comes from a nodes row so it
    # is present, user and attachable are set right here, `position` has a DB default, and
    # created_at/updated_at are stamped by record_timestamps.
    #
    # The dedupe is a pluck-and-reject rather than find_or_create_by per file for the same reason,
    # and it is load-bearing: maker_file_attachments has NO uniqueness index, so a second row for
    # one node is storable and would render the same file twice on the project page.
    def attach(files)
      return 0 if files.empty?

      existing = @project.file_attachments.where(node_id: files.map(&:node_id))
                         .pluck(:node_id).to_set
      rows = files.reject { |n| existing.include?(n.node_id) }.map do |node|
        { user_id: @user.id, attachable_type: "Maker::Project", attachable_id: @project.id,
          node_id: node.node_id, role: Maker::FileAttachment.role_for(node.name) }
      end
      return rows.size if rows.empty? || @dry_run

      Maker::FileAttachment.insert_all(rows)
      rows.size
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: PASS — every test in the file green, including the ones just added. (No exact count is given on purpose: this file grows across Tasks 4-8, and a stale literal here would read as a failure.)

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/project_intake.rb test/services/maker/project_intake_test.rb
git commit -m "feat(projects): attach every file under a project's folder

Reads nodes — the catalog all three backends populate — so it covers all six
write doors without touching any of them, and a seventh cannot silently skip
the rule. One query per tree level, one INSERT for the rows.

It READS folder_node_id and never calls ensure_library_folder!: calling it
would make a sweep create Projects/<slug> for every project that never had
one, which is the side-effect bug #relocate shipped, at library scale."
```

---

## Task 5: `ProjectIntake` — the filing step

**Files:**
- Modify: `app/services/maker/project_intake.rb`
- Test: `test/services/maker/project_intake_test.rb`

- [ ] **Step 1: Write the failing test**

Append inside `class ProjectIntakeTest`, after the attach-step tests:

```ruby
    # --- the filing step ---------------------------------------------------------

    def parent_name(node) = @user.nodes.find_by(node_id: node.reload.parent_node_id)&.name

    test "a loose file at the root is filed into its category folder" do
      node = file("panel.svg")
      result = intake
      assert_equal 1, result.moved
      assert_equal "design", parent_name(node)
    end

    test "each category gets its own folder, created only when needed" do
      svg = file("panel.svg")
      nc = file("pocket.nc")
      intake
      assert_equal "design", parent_name(svg)
      assert_equal "cnc", parent_name(nc)
      # LAZY: only the two folders that were needed exist, not all nine.
      made = @user.nodes.present.where(parent_node_id: @folder.node_id, kind: "dir").pluck(:name)
      assert_equal %w[cnc design], made.sort
    end

    # ROOT = INBOX. A file the user filed by hand — even "wrong" — is never touched again.
    test "a file already in a subfolder is left exactly where it is" do
      sub = dir("cnc")
      node = file("panel.svg", parent: sub.node_id) # svg in cnc/ is "wrong", and that is allowed
      result = intake
      assert_equal 0, result.moved
      assert_equal "cnc", parent_name(node)
    end

    test "filing is idempotent — a second run moves nothing" do
      file("panel.svg")
      assert_equal 1, intake.moved
      assert_equal 0, intake.moved
    end

    test "the node_id survives the move, so attachments keep pointing at it" do
      node = file("panel.svg")
      intake
      assert @project.file_attachments.exists?(node_id: node.node_id)
      assert_equal node.node_id, @user.nodes.find_by(name: "panel.svg").node_id
    end

    test "a directory at the root is not moved" do
      d = dir("loose")
      assert_equal 0, intake.moved
      assert_equal @folder.node_id, d.reload.parent_node_id
    end

    # THE THREE EXISTING RULES MUST NOT BE BYPASSED BY THIS THIRD DOOR. Maker::AttachToProject's
    # header records #relocate being written below all of them and gutting a model bundle while
    # reporting success.
    test "a model's file is not filed — the bundle rule still applies" do
      model = @user.maker_models.create!(title: "Widget")
      node = file("widget.stl")
      model.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      result = intake
      assert_equal 0, result.moved
      assert_equal @folder.node_id, node.reload.parent_node_id
    end

    test "a file another project claims is not filed" do
      other = @user.maker_projects.create!(name: "Bench")
      node = file("shared.stl")
      other.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      assert_equal 0, intake.moved
      assert_equal @folder.node_id, node.reload.parent_node_id
    end

    # A collision leaves the file at the root AND keeps the attachment — the attach is the durable
    # half, the move is best-effort (Maker::AttachToProject's rule, applied here).
    test "a name already taken in the destination leaves the file at the root, still attached" do
      sub = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, "design" ])
      file("panel.svg", parent: sub.node_id)
      loose = file("panel.svg")
      result = intake
      assert_equal 0, result.moved
      assert_equal 1, result.skipped
      assert_equal @folder.node_id, loose.reload.parent_node_id
      assert @project.file_attachments.exists?(node_id: loose.node_id),
             "the attach is durable — a failed move must not cost the reference"
    end

    test "one collision does not stop the rest of the sweep" do
      sub = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, "design" ])
      file("panel.svg", parent: sub.node_id)
      file("panel.svg")          # collides
      ok = file("pocket.nc")     # must still be filed
      result = intake
      assert_equal 1, result.moved
      assert_equal 1, result.skipped
      assert_equal "cnc", parent_name(ok)
    end

    test "move: false attaches without filing anything" do
      node = file("panel.svg")
      result = Maker::ProjectIntake.for_project(user: @user, project: @project, move: false)
      assert_equal 1, result.attached
      assert_equal 0, result.moved
      assert_equal @folder.node_id, node.reload.parent_node_id
    end

    # --- dry run -----------------------------------------------------------------

    test "a dry run writes nothing at all — not even the attachment rows" do
      node = file("panel.svg")
      result = Maker::ProjectIntake.for_project(user: @user, project: @project, dry_run: true)
      assert_equal 1, result.attached
      assert_equal 1, result.moved
      assert_equal [ [ "panel.svg", "design" ] ], result.plan
      assert_equal 0, @project.file_attachments.count, "a dry run must write no attachment rows"
      assert_equal @folder.node_id, node.reload.parent_node_id
      assert_not @user.nodes.present.exists?(parent_node_id: @folder.node_id, kind: "dir"),
                 "a dry run must not create the category folder either"
    end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: FAIL. The filing tests fail on `Expected: 1 Actual: 0` for `result.moved` — `#call` returns `moved: 0` unconditionally so far.

- [ ] **Step 3: Add the filing step**

In `app/services/maker/project_intake.rb`, replace `#call` with:

```ruby
    def call
      folder = live_folder
      return Result.new(attached: 0, moved: 0, skipped: 0, plan: [], status: :no_folder) unless folder

      files = subtree_files(folder)
      # ATTACH FIRST, AND THE ORDER IS LOAD-BEARING. It inherits Maker::AttachToProject's rule that
      # the attach is the DURABLE half and the move is BEST-EFFORT: a collision or an unmounted NAS
      # must never cost the user a reference they asked for, and the reference is exactly as true
      # with the bytes still sitting at the root.
      attached = attach(files)
      return Result.new(attached:, moved: 0, skipped: 0, plan: [], status: :ok) unless @move

      # THE INBOX IS THE ROOT, AND ONLY THE ROOT. Anything already in a subfolder is the user's
      # filing — including filing we would disagree with — and position is what records that, so
      # there is no state to keep. Re-filing a subfolder would fight the user every 15 minutes, and
      # on chunk each round of that fight is a changelog entry broadcast to every device.
      inbox = files.select { |n| n.parent_node_id == folder.node_id }
      moved, skipped, plan = file_all(inbox)

      Result.new(attached:, moved:, skipped:, plan:, status: :ok)
    end
```

Then add these private methods below `#attach`:

```ruby
    # File each loose file, counting outcomes. Returns [moved, skipped, plan].
    def file_all(inbox)
      moved = 0
      skipped = 0
      plan = []
      inbox.each do |node|
        dest = place(node)
        if dest
          moved += 1
          plan << [ node.name, dest ]
        else
          skipped += 1
        end
      end
      [ moved, skipped, plan ]
    end

    # Move one file into its category folder. Answers the folder name, or nil if it stayed put.
    #
    # IT ASKS Maker::AttachToProject#refusal_for FIRST, and that is this method's most important
    # line. Those three rules (:not_a_file, :model_bundle, :attached_elsewhere) are policy about
    # where a file may be moved to, and #refusal_for is PUBLIC precisely so a second door can ask
    # rather than reimplement. The class's own header records what happens otherwise: when
    # #relocate was added it called the move BELOW all three, and silently pulled one file out of a
    # model's bundle folder while reporting success. This is the third door.
    #
    # FetchError IS DELIBERATELY NOT RESCUED HERE — it means the library is unreachable, so every
    # remaining move would fail identically, and #file_all's caller turns it into one abort rather
    # than N identical log lines. Adding it to this list would make an unmounted NAS log once per
    # file and pretend each one was an independent skip.
    #
    # InvalidName IS DELIBERATELY ABSENT TOO. The name comes from an existing `nodes` row, which
    # #leaf! has already vetted — there is no producer on this path. Maker::AttachToProject#move
    # records what a too-wide rescue costs: it caught bare ArgumentError until a review drove the
    # consequence that arity drift, a kwarg rename, or a nil reaching File.extname all became a
    # flash message with a green suite.
    def place(node)
      return nil if attach_policy.refusal_for(node)

      dest = Maker::ProjectFolders.folder_for(node.name)
      # Before ensure_path!, so a dry run creates no folder — the reason it is a `dry run` and not
      # a `report`.
      return dest if @dry_run

      target = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, dest ])
      Maker::MoveNode.call(@user, node:, new_parent_node_id: target.node_id)
      dest
    rescue Maker::MoveNode::Collision, FileLayer::NotFound, FileLayer::UnsupportedOperation => e
      # INFO, not warn: each of these is an ordinary thing that happens to a user's library, and the
      # per-project summary line is where the operator-visible count lives. A warn per file would
      # make a single permanently-colliding name noise every 15 minutes forever.
      Rails.logger.info("Maker::ProjectIntake: left #{node.name.inspect} at the root of " \
                        "#{@project.slug} — #{e.class}")
      nil
    end

    # Memoized: #refusal_for runs per file and the object holds no per-file state.
    def attach_policy
      @attach_policy ||= Maker::AttachToProject.new(user: @user, project: @project)
    end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: PASS — every test in the file green, including the ones just added. (No exact count is given on purpose: this file grows across Tasks 4-8, and a stale literal here would read as a failure.)

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/project_intake.rb test/services/maker/project_intake_test.rb
git commit -m "feat(projects): file loose files into category subfolders

Root = inbox: only files at the project folder's root are filed, so anything
already in a subfolder is the user's filing and is never touched again. Position
is the marker, so there is no state to keep — and no fight every 15 minutes.

It asks AttachToProject#refusal_for before every move. That method is public
precisely so a second door can ask instead of reimplementing, and this is the
third: the class's header records #relocate being written below all three rules
and gutting a model bundle while reporting success.

Category folders are created lazily, so a project gets the two it needs rather
than all nine (nine changelog entries per project, on chunk)."
```

---

## Task 6: Abort the project's sweep when the library is unreachable

**Files:**
- Modify: `app/services/maker/project_intake.rb`
- Test: `test/services/maker/project_intake_test.rb`

- [ ] **Step 1: Write the failing test**

**`Object#stub` DOES NOT EXIST IN THIS SUITE.** minitest 6 dropped `minitest/mock`, and requiring it is a `LoadError`, not a missing-gem warning (recorded at `test/jobs/maker/generate_preview_job_test.rb:19`). Fakes are hand-rolled with `define_singleton_method` and restored in an `ensure`. The idiom to copy is `with_broken_move` at `test/integration/web/attach_auto_move_test.rb:39`.

Append inside `class ProjectIntakeTest`:

```ruby
    # --- an unreachable library --------------------------------------------------

    # A backend whose `move` always raises, counting attempts. Hand-rolled rather than Object#stub:
    # minitest 6 DROPPED minitest/mock, so `stub` does not exist in this suite (requiring it is a
    # LoadError). Modelled on with_broken_move in attach_auto_move_test.rb.
    #
    # `port_writable? = true` sends Maker::MoveNode through the port door, straight into `move`. The
    # fake defines NO mkdir — which is why every test below seeds the destination folder first: with
    # it already in the catalog, Maker::LibraryFolder#ensure_segment returns the existing node and
    # never reaches the port. Without that seeding the failure would be a NoMethodError on mkdir,
    # i.e. the test would pass for the wrong reason.
    def with_broken_move(error_class)
      attempts = 0
      broken = Object.new
      def broken.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      broken.define_singleton_method(:move) do |*|
        attempts += 1
        raise(error_class, "the backend is having a bad day")
      end
      FileLayer.current = broken
      yield -> { attempts }
    ensure
      FileLayer.reset!
    end

    def seed_folder(name)
      Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, name ])
    end

    # An unmounted NAS fails EVERY move identically, so the honest answer is one abort and one log
    # line — not N skips pretending each was independent.
    test "a FetchError aborts this project's sweep after one attempt, counting the rest skipped" do
      seed_folder("design") # so ensure_path! never reaches the fake's absent mkdir
      file("a.svg")
      file("b.svg")
      file("c.svg")

      with_broken_move(FileLayer::FetchError) do |attempts|
        result = intake
        assert_equal 0, result.moved
        assert_equal 3, result.skipped
        assert_equal 1, attempts.call, "it must stop after the first FetchError, not try all three"
        assert_equal :ok, result.status
        # THE DETAIL MUST SURVIVE THE ABORT, and every unprocessed file is named — including the
        # one that raised. A count alone would tell an operator three files did not move without
        # telling them which, which is the gap `skips` was added to close.
        assert_equal %i[unavailable unavailable unavailable], result.skips.map(&:last)
        assert_equal %w[a.svg b.svg c.svg], result.skips.map(&:first).sort
      end
    end

    # The attach still happened — it is the durable half and it touches no bytes.
    test "an unreachable library still leaves the attachments behind" do
      seed_folder("design")
      file("a.svg")
      with_broken_move(FileLayer::FetchError) do
        assert_equal 1, intake.attached
      end
      assert_equal 1, @project.file_attachments.count
    end

    # CONTRAST, and it is what proves the two rescues are in different places: a per-file condition
    # must NOT abort the sweep. Both files are attempted.
    test "an UnsupportedOperation is per-file and does not abort the sweep" do
      seed_folder("design")
      file("a.svg")
      file("b.svg")

      with_broken_move(FileLayer::UnsupportedOperation) do |attempts|
        result = intake
        assert_equal 0, result.moved
        assert_equal 2, result.skipped
        assert_equal 2, attempts.call, "a per-file refusal must not stop the file after it"
      end
    end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/maker/project_intake_test.rb -n "/FetchError|unreachable|UnsupportedOperation/"
```

Expected: the two FetchError tests FAIL with `FileLayer::FetchError: the backend is having a bad day` escaping the service — nothing rescues it yet. The `UnsupportedOperation` test already PASSES (Task 5's `#place` rescues it), and that is the point of including it here: it is the control that shows the next step's rescue is scoped differently.

- [ ] **Step 3: Add the abort**

**The `#file_all` code block below supersedes the one this plan originally carried.** Task 5's review
added a `skips` member to `Result` (an array of `[name, reason]`, symmetric with `plan`), so
`#file_all` now returns FOUR values — `[moved, skipped, skips, plan]` — and `#place` answers a
folder-name String on success or a reason Symbol on failure. Write the abort against the CURRENT
shape in the file, not the three-value one.

Required behaviour, which the tests pin:

- The rescue for `FileLayer::FetchError` wraps the whole loop, NOT each file. Every remaining move
  would fail identically, so it is one abort and one log line, not N.
- `moved`, `plan` and any `skips` already recorded before the failure are KEPT.
- Every file not yet processed — **including the one that raised** — is appended to `skips` with the
  reason **`:unavailable`**, matching `AttachToProject#move`'s existing vocabulary for "the library
  is having a bad day, try later". Do not invent a second spelling.
- `skipped` stays `skips.size`, so the count and the detail cannot disagree.
- The log line is `warn`, names the project slug and the error class and message, and states how
  many were filed before it stopped.

Write it in whatever shape reads cleanest against the current method; the contract above and the
tests are what must hold. Do not restructure `#place`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: PASS — every test in the file green, including the ones just added. (No exact count is given on purpose: this file grows across Tasks 4-8, and a stale literal here would read as a failure.)

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/project_intake.rb test/services/maker/project_intake_test.rb
git commit -m "feat(projects): one abort for an unreachable library, not N skips

A FetchError is about the LIBRARY, not the file: every remaining move fails
identically, so rescuing it per file would log once per file and report each as
an independent skip — reading like a library of individually-broken files
rather than one unmounted NAS. The per-file rescue in #place stays narrow."
```

---

## Task 7: The run-level cap

**Files:**
- Modify: `app/services/maker/project_intake.rb`
- Test: `test/services/maker/project_intake_test.rb`

**Note on scope.** The cap is **per run (one user), not per project** — a per-project cap of 500 lets fifty projects move 25,000 files without tripping, which bounds the wrong thing. So it lives in a new `.for_user` entry point, and `.for_project` keeps no cap logic at all.

- [ ] **Step 1: Write the failing test**

Append inside `class ProjectIntakeTest`:

```ruby
    # --- for_user and the run cap ------------------------------------------------

    test "for_user sweeps every project that has a folder" do
      bench = @user.maker_projects.create!(name: "Bench")
      bench_folder = bench.ensure_library_folder!(@user)
      file("panel.svg")
      file("pocket.nc", parent: bench_folder.node_id)

      run = Maker::ProjectIntake.for_user(user: @user)
      assert_equal :ok, run.status
      assert_equal 2, run.results.size
      assert_equal 2, run.results.sum { |_p, r| r.moved }
    end

    test "for_user skips projects with no folder without creating one" do
      @user.maker_projects.create!(name: "Nothing Yet")
      run = Maker::ProjectIntake.for_user(user: @user)
      assert_equal 1, run.results.size, "a folderless project is not even visited"
    end

    # THE CAP'S DESIGN, AND THE HALF A TEST THAT ONLY COUNTS MOVES WOULD MISS: over the cap,
    # NOTHING MOVES AND EVERYTHING STILL ATTACHES.
    test "over the cap nothing is filed but everything is still attached" do
      3.times { |i| file("p#{i}.svg") }
      run = Maker::ProjectIntake.for_user(user: @user, cap: 2)
      assert_equal :refused_too_many_moves, run.status
      assert_equal 3, run.inbox_total
      assert_equal 2, run.cap
      assert_equal 0, run.results.sum { |_p, r| r.moved }
      assert_equal 3, run.results.sum { |_p, r| r.attached },
                    "the attach step writes no bytes, so the cap has no reason to withhold it"
      assert_equal 3, @project.file_attachments.count
    end

    # Checked BEFORE the first move, not enforced by stopping partway: a partial sweep would pace
    # the work into batches and file the whole library anyway, 500 at a time, guarding nothing.
    test "the cap moves nothing at all, rather than moving up to the cap" do
      3.times { |i| file("p#{i}.svg") }
      Maker::ProjectIntake.for_user(user: @user, cap: 2)
      assert_equal 0, @user.nodes.present.where(parent_node_id: @folder.node_id, kind: "dir").count,
                   "not one move happened, so not one category folder was created"
    end

    test "at exactly the cap it proceeds" do
      2.times { |i| file("p#{i}.svg") }
      run = Maker::ProjectIntake.for_user(user: @user, cap: 2)
      assert_equal :ok, run.status
      assert_equal 2, run.results.sum { |_p, r| r.moved }
    end

    # The cap counts across the RUN, not per project — a per-project cap would bound the wrong thing.
    test "the cap sums every project's inbox" do
      bench = @user.maker_projects.create!(name: "Bench")
      bench_folder = bench.ensure_library_folder!(@user)
      2.times { |i| file("a#{i}.svg") }
      2.times { |i| file("b#{i}.svg", parent: bench_folder.node_id) }

      run = Maker::ProjectIntake.for_user(user: @user, cap: 3)
      assert_equal :refused_too_many_moves, run.status
      assert_equal 4, run.inbox_total
    end

    # A dry run must never refuse: seeing the number is the entire reason to run one.
    test "a dry run reports over the cap instead of refusing" do
      3.times { |i| file("p#{i}.svg") }
      run = Maker::ProjectIntake.for_user(user: @user, cap: 1, dry_run: true)
      assert_equal :ok, run.status
      assert_equal 3, run.results.sum { |_p, r| r.moved }
    end

    # READ PER CALL, never frozen at boot: the log line names this variable as the way out, and a
    # boot-frozen value makes that advice false in a running process and unreachable from a test —
    # which is how an escape hatch rots shut (Library::Reconciler#max_delete_pct's recorded lesson).
    test "PROJECT_ORGANIZE_MAX_MOVES is honored per call" do
      3.times { |i| file("p#{i}.svg") }
      prior = ENV["PROJECT_ORGANIZE_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_MAX_MOVES"] = "1"
      begin
        assert_equal 1, Maker::ProjectIntake.max_moves
        assert_equal :refused_too_many_moves, Maker::ProjectIntake.for_user(user: @user).status
      ensure
        ENV["PROJECT_ORGANIZE_MAX_MOVES"] = prior
      end
    end

    test "the default cap is 500" do
      assert_equal 500, Maker::ProjectIntake::MAX_MOVES
      assert_equal 500, Maker::ProjectIntake.max_moves
    end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: FAIL with `NoMethodError: undefined method 'for_user' for Maker::ProjectIntake`.

- [ ] **Step 3: Add `for_user`, `max_moves`, `MAX_MOVES` and `RunResult`**

In `app/services/maker/project_intake.rb`, add below the `Result` definition:

```ruby
    # What one USER's whole intake run did. The cap is a property of the RUN, so its refusal lives
    # here rather than on Result: a single project cannot know whether the run as a whole is
    # implausible.
    RunResult = Data.define(:results, :status, :inbox_total, :cap)

    # The default ceiling on files filed in one run. See .for_user for why it is an absolute count
    # rather than a percentage.
    MAX_MOVES = 500
```

Then add these class methods below `.for_project`:

```ruby
    # Sweep every one of this user's projects that HAS a folder, under one shared cap.
    #
    # THE CAP IS ABSOLUTE, NOT A PERCENTAGE, and Library::Reconciler's mass-deletion guard is the
    # wrong model here — which is worth saying because copying it looks like the safe choice. A
    # percentage needs a denominator, and the only honest one is "files currently at project roots",
    # of which the intended first run files 100%. A percentage would be guarding against SUCCESS.
    # The diagnostic number is the raw count: 40 files at project roots is a few projects, 40,000 is
    # a misconfiguration.
    #
    # IT IS PER RUN, NOT PER PROJECT. A per-project cap of 500 lets fifty projects move 25,000 files
    # without ever tripping — it would bound the wrong thing, since the blast radius that matters is
    # the churn ONE run produces on the NAS or on the changelog.
    #
    # OVER THE CAP, THE ATTACH STEP STILL RUNS. The two halves have different costs: an attach
    # writes a row and moves no bytes, so there is nothing to be careful about, and withholding it
    # would deny the harmless half of the feature out of concern for the other. That is the
    # durable/best-effort split applied to the guard itself.
    #
    # IT ANSWERS A STATUS AND DOES NOT RAISE, unlike Library::Scanner::UnsafeScan, for two reasons —
    # and the second is the load-bearing one. A cap trip on a big first run is an EXPECTED outcome,
    # not a malfunction (Maker::AttachToProject's argument for every move outcome being a symbol:
    # "each one is a normal thing that happens to a user's library"). And on share/s3 this is called
    # at the END of Library::ScanJob#perform, where there is no transaction — so a raise would fail a
    # job whose scan had ALREADY SUCCEEDED AND COMMITTED, telling an operator the library did not
    # index when it did. A guard must not lie about which operation it stopped.
    #
    # WHAT IT DOES NOT PROTECT AGAINST, so it is not mistaken for covered: it bounds VOLUME, not
    # correctness. There is no data loss to guard — node_id never changes (the port's stated
    # promise), so every attachment, BOM link and tag survives a move, and the move is reversible by
    # dragging the file back. That asymmetry is exactly why a count suffices here where a percentage
    # of the library was necessary there.
    def self.for_user(user:, dry_run: false, cap: nil)
      projects = user.maker_projects.where.not(folder_node_id: nil).to_a
      return RunResult.new(results: [], status: :ok, inbox_total: 0, cap: cap || max_moves) if projects.empty?

      cap ||= max_moves
      # ONE query for the whole run's inbox, and it is what makes "checked before the first move"
      # true. An observer cannot decide this per project: the cap is a property of the run.
      inbox_total = user.nodes.present
                        .where(kind: "file", parent_node_id: projects.map(&:folder_node_id)).count

      # A dry run never refuses — seeing this number is the entire reason to run one.
      refused = !dry_run && inbox_total > cap
      results = projects.map do |project|
        [ project, for_project(user:, project:, dry_run:, move: !refused) ]
      end

      RunResult.new(results:, status: refused ? :refused_too_many_moves : :ok, inbox_total:, cap:)
    end

    # READ PER CALL, never frozen into a constant at boot. The refusal's log line names this
    # variable as the operator's way out, and a value fixed at boot makes that advice false inside a
    # running process and unreachable from a test — which is how an escape hatch rots shut. That is
    # Library::Reconciler#max_delete_pct's recorded lesson, and it applies verbatim. One ENV fetch
    # per run costs nothing.
    def self.max_moves
      Integer(ENV.fetch("PROJECT_ORGANIZE_MAX_MOVES", MAX_MOVES.to_s))
    end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: PASS — every test in the file green, including the ones just added. (No exact count is given on purpose: this file grows across Tasks 4-8, and a stale literal here would read as a failure.)

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/project_intake.rb test/services/maker/project_intake_test.rb
git commit -m "feat(projects): an absolute, run-scoped cap on files filed per run

Absolute, not a percentage: a percentage needs a denominator, the only honest
one is 'files at project roots', and the intended first run files 100% of them
— it would be guarding against success. Per RUN, not per project, or fifty
projects move 25,000 files without tripping.

Over the cap nothing moves and everything still attaches: an attach writes a
row and moves no bytes, so withholding it would deny the harmless half.

It answers a status rather than raising. On share/s3 this runs at the END of
ScanJob#perform with no transaction, so a raise would fail a job whose scan
already succeeded and committed — telling the operator the library did not
index when it did."
```

---

## Task 8: `for_node` — the single-file entry point

**Files:**
- Modify: `app/services/maker/project_intake.rb`
- Test: `test/services/maker/project_intake_test.rb`

- [ ] **Step 1: Write the failing test**

Append inside `class ProjectIntakeTest`:

```ruby
    # --- for_node ----------------------------------------------------------------

    test "for_node files a file dropped at a project root" do
      node = file("panel.svg")
      result = Maker::ProjectIntake.for_node(user: @user, node:)
      assert_equal 1, result.moved
      assert_equal "design", parent_name(node)
    end

    # The upload chooser can target a category subfolder directly, so the project is one hop up.
    test "for_node resolves the project from inside a category subfolder" do
      sub = dir("design")
      node = file("panel.svg", parent: sub.node_id)
      result = Maker::ProjectIntake.for_node(user: @user, node:)
      assert_not_nil result
      assert_equal 1, result.attached
      assert_equal "design", parent_name(node), "already filed — it must not move again"
    end

    test "for_node answers nil for a file outside every project folder" do
      node = file("stray.stl", parent: nil)
      assert_nil Maker::ProjectIntake.for_node(user: @user, node:)
    end

    test "for_node answers nil when the user has no project folders" do
      other = User.create!(email: "pin-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      node = other.nodes.create!(node_id: SecureRandom.uuid, name: "a.svg", kind: "file")
      assert_nil Maker::ProjectIntake.for_node(user: other, node:)
    end

    # THE HOLE THIS CLOSES: if the periodic run REFUSED on the cap, an uncapped for_node would file
    # the library anyway, one upload at a time, and the guard would guard nothing.
    test "for_node respects the cap, so a refused library stays refused" do
      3.times { |i| file("p#{i}.svg") }
      node = file("trigger.svg")
      prior = ENV["PROJECT_ORGANIZE_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_MAX_MOVES"] = "2"
      begin
        result = Maker::ProjectIntake.for_node(user: @user, node:)
        assert_equal 0, result.moved
        assert_equal 4, result.attached, "the attach half still runs, as it does for a whole run"
      ensure
        ENV["PROJECT_ORGANIZE_MAX_MOVES"] = prior
      end
    end

    # A cycle in `nodes` must terminate rather than spin — fatal on SQLite, which has no statement
    # timeout. Reachable only via a crafted/corrupt tree, which is why it is a backstop and not a
    # feature.
    test "for_node terminates on a parent cycle" do
      a = dir("a")
      b = dir("b", parent: a.node_id)
      a.update!(parent_node_id: b.node_id)
      node = file("x.svg", parent: b.node_id)
      assert_nil Maker::ProjectIntake.for_node(user: @user, node:)
    end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: FAIL with `NoMethodError: undefined method 'for_node' for Maker::ProjectIntake`.

- [ ] **Step 3: Add `for_node` and `owning_project`**

In `app/services/maker/project_intake.rb`, add below `.for_user`:

```ruby
    # Intake for the project that owns ONE node — the eager nudge's entry point, so a web upload
    # into a project folder attaches and files itself NOW rather than at the next sweep, which would
    # read as broken. Answers nil when the node is not under any project folder.
    #
    # It sweeps the whole owning project rather than just this node. That is deliberate: the policy
    # is identical, the work is bounded by one project's inbox, and a single-file path would be a
    # second copy of the two steps — the thing this class exists to avoid having.
    #
    # IT APPLIES THE CAP, and that is not belt-and-braces. Without it, a run that REFUSED on the cap
    # would be undone by uploads: each one would file that project's whole inbox, and the guard
    # would guard nothing. Scoped to this project's inbox because that is the only count this entry
    # point can honestly take.
    def self.for_node(user:, node:)
      project = owning_project(user, node)
      return nil unless project

      inbox = user.nodes.present.where(kind: "file", parent_node_id: project.folder_node_id).count
      cap = max_moves
      if inbox > cap
        Rails.logger.warn("Maker::ProjectIntake: attaching but NOT filing #{project.slug} — " \
                          "#{inbox} loose files is over the #{cap} cap. Run " \
                          "`rake projects:organize` (it lifts the cap) or raise " \
                          "PROJECT_ORGANIZE_MAX_MOVES.")
      end
      for_project(user:, project:, move: inbox <= cap)
    end

    # The project whose library folder is an ancestor of `node`, or nil.
    #
    # Walks UP, one query per level, bounded by MAX_DEPTH with a visited set for the same reason the
    # subtree walk is: a cycle in `nodes` makes an unbounded walk spin, which is fatal on SQLite (no
    # statement timeout). One pluck up front means the loop compares against a hash rather than
    # querying maker_projects per level.
    def self.owning_project(user, node)
      by_folder = user.maker_projects.where.not(folder_node_id: nil)
                      .pluck(:folder_node_id, :id).to_h
      return nil if by_folder.empty?

      current = node.parent_node_id
      seen = Set.new
      MAX_DEPTH.times do
        return nil if current.blank?
        id = by_folder[current]
        return user.maker_projects.find_by(id:) if id
        return nil unless seen.add?(current)
        current = user.nodes.where(node_id: current).pick(:parent_node_id)
      end
      nil
    end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: PASS — every test in the file green, including the ones just added. (No exact count is given on purpose: this file grows across Tasks 4-8, and a stale literal here would read as a failure.)

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/project_intake.rb test/services/maker/project_intake_test.rb
git commit -m "feat(projects): for_node, the eager-nudge entry point

Resolves the owning project by walking up from the node — bounded, visited-set,
because a cycle in nodes spins unboundedly and that is fatal on SQLite.

It applies the cap, and that is not belt-and-braces: without it a run that
refused on the cap would be undone by uploads, each filing that project's whole
inbox, and the guard would guard nothing."
```

---

## RESOLVED BLOCKER on Task 9, found during Task 4's review (2026-07-30)

**Closed by Task 9a** (`d9315ec` + `48853aa`), added during execution. A migration deduped
`maker_file_attachments` (keeping the lowest id per group, the tie-break
`AttachToProject#model_owning` already uses) and added a unique index on
`(user_id, attachable_type, attachable_id, node_id)`; `ProjectIntake#attach` now passes
`unique_by:`. Local dev and test databases held **zero** duplicates.

**Two corrections came out of it, both worth keeping:**

1. **Bare `insert_all(rows)` does NOT raise on conflict.** Rails hardcodes `on_duplicate: :skip`
   and resolves an absent `unique_by:` to an untargeted `ON CONFLICT DO NOTHING`. So the INDEX
   alone closed the race; `unique_by:` buys precision — it scopes the swallowed conflict to this
   tuple, so a future unrelated unique constraint on the table is not silently absorbed too.
2. **`find_or_create_by!` was never the 500 path it was reported to be.** In ActiveRecord 8.1.3
   it is `find_by(attributes) || create_or_find_by!(attributes, &block)` — verified in the gem
   source — so its fallback already went through a `RecordNotUnique` rescue. The real exposures
   were the bare `create!` sites (`Models::AttachmentsController`, `Projects::EntryPhotosController`,
   `CurrentProject#attach_addon_files_to_current_project`), where the index turned a silent
   duplicate into an uncaught 500 — and, in `CurrentProject`'s case, into a silently abandoned
   BATCH, since its loop runs in a transaction under a broad `rescue StandardError`.

The original analysis is kept below because its reasoning about WHY a periodic writer changes the
risk profile is still the argument for having done this at all.

---

## The original blocker note



**A duplicate-attachment race must be resolved before the periodic job is wired.**

`ProjectIntake#attach` reads which node_ids are already attached, then `insert_all`s the rest —
no transaction between the two, and `maker_file_attachments` has **no uniqueness index**. If any
other writer attaches the same file inside that window, the sweep writes a second row and the
project page renders the file twice, which is the exact failure `#attach`'s own comment names.

**It is inherited, not introduced:** `AttachToProject#attach_bundle` has the identical
dedupe-then-bulk-insert shape today. What changes at Task 9 is the *risk profile*. Every existing
writer runs from a user action, so the window only opens on a rare double-submit. A periodic sweep
has no user to serialize against: one ordinary concurrent attach landing in the window is enough,
and it recurs every 15 minutes indefinitely.

**CLAUDE.md's stated reason for having no index is stale.** It says the table has no uniqueness
index because "this service is the only writer" — Task 4's review counted **five** writers:
`AttachToProject#call`, `Projects::UploadsController#create!`, `Models::AttachmentsController#create!`,
`CurrentProject#attach_addon_files_to_current_project`, and `Projects::EntryPhotosController#create!`.
`ProjectIntake` is the sixth.

**The fix is a unique index on `(user_id, attachable_type, attachable_id, node_id)` plus
`insert_all(..., unique_by:)`** — which requires a backfill dedupe first, because duplicate rows
may already exist in the three deployed libraries. That is a migration against production data and
it was in neither the spec nor this plan.

**Do not improvise this.** Before Task 9: measure how many duplicate rows exist on the deployed
chunk / share / s3 libraries, then decide the dedupe with that number in hand. If the count is
zero the index is cheap; if it is not, which row survives is a product decision (the oldest, by
`AttachToProject#model_owning`'s `order(:id)` precedent) and the `position` column complicates it.

---

## Task 9: The job and the chunk-mode schedule

**Files:**
- Create: `app/jobs/maker/project_intake_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/jobs/maker/project_intake_job_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/jobs/maker/project_intake_job_test.rb`:

```ruby
require "test_helper"

module Maker
  class ProjectIntakeJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      pin_file_layer_backend("chunk")
      @user = User.create!(email: "pij-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
    end

    def file(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                          parent_node_id: parent, size: 1, content_hash: SecureRandom.hex(8))
    end

    test "perform attaches and files" do
      node = file("panel.svg")
      Maker::ProjectIntakeJob.perform_now(user_id: @user.id)
      assert @project.file_attachments.exists?(node_id: node.node_id)
      assert_equal "design", @user.nodes.find_by(node_id: node.reload.parent_node_id).name
    end

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong — discard rather than record a failure (GeneratePreviewJob sets the precedent).
    test "a missing user is discarded, not failed" do
      assert_nothing_raised do
        perform_enqueued_jobs do
          Maker::ProjectIntakeJob.perform_later(user_id: 999_999_999)
        end
      end
    end

    # THE GATE IS ON THE FAN-OUT, NOT ON #perform — the house rule Library::ScanJob states: a
    # `return unless` inside #perform would make an operator's explicit run silently do nothing.
    test "sweep_all! enqueues for a chunk deployment" do
      assert_enqueued_with(job: Maker::ProjectIntakeJob) do
        Maker::ProjectIntakeJob.sweep_all!
      end
    end

    # On a SCANNED backend Library::ScanJob is already the caller. Running both would reintroduce
    # the scan overlap the design places this call to prevent.
    test "sweep_all! declines on a scannable backend" do
      root = Dir.mktmpdir("pij-share")
      begin
        FileLayer.current = FileLayer::Share.new(root:)
        assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
          Maker::ProjectIntakeJob.sweep_all!
        end
      ensure
        FileLayer.reset!
        FileUtils.remove_entry(root)
      end
    end

    # #perform has NO gate, so an explicit run works on any backend.
    test "perform still performs on a scannable backend" do
      node = file("panel.svg")
      assert_nothing_raised { Maker::ProjectIntakeJob.perform_now(user_id: @user.id) }
      assert @project.file_attachments.exists?(node_id: node.node_id)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/jobs/maker/project_intake_job_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Maker::ProjectIntakeJob`.

- [ ] **Step 3: Write the job**

Create `app/jobs/maker/project_intake_job.rb`:

```ruby
module Maker
  # Periodic project-folder intake: attach what is under each project folder, file what is loose at
  # its root. Scheduled from config/recurring.yml.
  #
  # THE SCHEDULE IS FOR CHUNK DEPLOYMENTS ONLY, and .sweep_all! is where that is decided. On a
  # scanned backend (share/s3) Library::ScanJob calls the intake at the end of its own #perform, so
  # the two are strictly sequential; a second, scheduled caller would reintroduce exactly the
  # overlap that placement exists to prevent — a move made after the Scanner captured its
  # observations gets paired back by (content_hash, size), leaving the node pointed at a path with
  # no bytes until the next scan.
  #
  # THE GATE IS ON THE FAN-OUT, NOT ON #perform, and the distinction is Library::ScanJob's, stated
  # there: `sweep_all!` is a SCHEDULE, so declining to enqueue is a real answer, while #perform is a
  # COMMAND — a caller named a user, and a `return unless` there would make an operator's explicit
  # run silently do nothing. It also asks a CAPABILITY rather than a class, per the Phase 3 trap
  # `is_a?(Share)` shipped: a gate that names classes answers false for the next backend and
  # silently never runs.
  class ProjectIntakeJob < ApplicationJob
    queue_as :background

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong — discard rather than record a failure (GeneratePreviewJob sets the precedent).
    discard_on ActiveRecord::RecordNotFound

    def perform(user_id:)
      user = User.find(user_id)
      run = Maker::ProjectIntake.for_user(user:)
      report(run, user)
      run
    end

    def self.sweep_all!
      return if FileLayer.current.capabilities.scannable?

      User.find_each { |user| perform_later(user_id: user.id) }
    end

    private

    # THE LOG IS THE ENTIRE AUDIT TRAIL. Nothing persists a marker for what was filed, so these
    # lines are the only record of it — the same argument Maker::AttachToProject#log_failure makes,
    # and the counts are behaviour rather than phrasing.
    #
    # ONE LINE PER PROJECT THAT DID SOMETHING, so a steady state (every 15 minutes, forever,
    # nothing loose) is silent instead of printing a row of zeroes per project per quarter hour.
    def report(run, user)
      if run.status == :refused_too_many_moves
        Rails.logger.warn("Maker::ProjectIntakeJob: attached, but REFUSED to file " \
                          "#{run.inbox_total} loose files for user #{user.id} — over the " \
                          "#{run.cap} cap. Inspect with `DRY_RUN=1 rake projects:organize`, then " \
                          "run `rake projects:organize` (it lifts the cap) or raise " \
                          "PROJECT_ORGANIZE_MAX_MOVES.")
      end

      run.results.each do |project, result|
        next if result.attached.zero? && result.moved.zero? && result.skipped.zero?

        Rails.logger.info("Maker::ProjectIntakeJob #{project.slug}: attached #{result.attached}, " \
                          "filed #{result.moved}, left #{result.skipped}")
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/jobs/maker/project_intake_job_test.rb
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Add the schedule entry**

Append to the `production:` block of `config/recurring.yml`:

```yaml
  # Project-folder intake: attach what is under each Projects/<slug>/ folder, file what is loose at
  # its root. CHUNK DEPLOYMENTS ONLY — sweep_all! declines when the backend is `scannable`, because
  # on share/s3 Library::ScanJob already calls the intake at the end of its own perform, strictly
  # after the reconcile. A second caller there would reintroduce the scan overlap that placement
  # exists to prevent (a move made after the Scanner captured its observations is paired back by
  # content hash, leaving the node pointed at a path with no bytes until the next scan).
  #
  # `command:` rather than `class:`, matching library_scan, because the backend gate lives in a
  # class method rather than in #perform — a caller who names a user deserves the operation. Every
  # 15 minutes: the interval library_scan already establishes, so both deployments have the same
  # worst-case lateness rather than two numbers to reason about.
  project_folder_intake:
    command: "Maker::ProjectIntakeJob.sweep_all!"
    schedule: every 15 minutes
```

- [ ] **Step 6: Verify the schedule guard passes**

```bash
bin/rails test test/recurring_schedule_test.rb
```

Expected: PASS. This test parses `recurring.yml` and resolves every constant a `command:` names — `config/recurring.yml` is loaded by the Solid Queue **supervisor**, not by the Rails process the suite boots, so a typo here is otherwise invisible until 5am in production.

- [ ] **Step 7: Commit**

```bash
git add app/jobs/maker/project_intake_job.rb config/recurring.yml test/jobs/maker/project_intake_job_test.rb
git commit -m "feat(projects): the intake job, scheduled for chunk deployments only

sweep_all! declines when the backend is scannable, because on share/s3
Library::ScanJob calls the intake at the end of its own perform — a second
scheduled caller would reintroduce the scan overlap that placement prevents.

The gate is on the fan-out, not #perform: a schedule may decline to enqueue,
but a caller who names a user deserves the operation. It asks a capability
rather than a class, per the Phase 3 trap is_a?(Share) shipped."
```

---

## Task 10: Call the intake from `ScanJob`, strictly after the reconcile

**Files:**
- Modify: `app/jobs/library/scan_job.rb:59-68`
- Test: `test/jobs/library/scan_job_test.rb`

- [ ] **Step 1: Write the failing test**

First read `test/jobs/library/scan_job_test.rb` to match its setup idiom — it is share-backed, so it already has a `Dir.mktmpdir` root and an inline `User.create!`. Reuse whatever it names them; the code below assumes `@user` and `@root`. **Check whether it already has an `UnsafeScan` propagation test** — if it does, do not add a second one.

Append a new nested class at the end of the file:

```ruby
  # The project-folder intake runs at the END of #perform. ORDER IS A CORRECTNESS CONSTRAINT, not
  # tidiness — see Maker::ProjectIntake and the spec's §5.
  #
  # PROVED BY EFFECT, NOT BY CALL-ORDER RECORDING, and that is deliberate on two counts. `stub` does
  # not exist in this suite (minitest 6 dropped minitest/mock — see
  # test/jobs/maker/generate_preview_job_test.rb:19), and more importantly a recorded order would
  # assert the implementation rather than the guarantee. Here the file exists ONLY on disk: the
  # intake can only attach a node the reconcile has already created, so an attachment at the end of
  # one #perform IS the proof that the reconcile ran first.
  class IntakeOrderTest < Library::ScanJobTest
    setup do
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
      # A file that exists on disk and in NO node row. Path must match the folder's storage_path.
      FileUtils.mkdir_p(File.join(@root, @folder.storage_path))
      File.binwrite(File.join(@root, @folder.storage_path, "panel.svg"), "<svg/>")
    end

    test "one perform indexes the file AND attaches and files it" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      att = @project.file_attachments.sole
      node = @user.nodes.find_by!(node_id: att.node_id)
      assert_equal "panel.svg", node.name
      assert_equal "vector", att.role
      assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name,
                   "the intake ran after the reconcile — it filed a node the reconcile created"
    end

    # A scan that SUCCEEDED must not be reported as failed because the intake blew up. The reconcile
    # is already committed (there is no transaction), so an operator reading a failed ScanJob would
    # conclude the library did not index — which would be false.
    #
    # Hand-rolled override with an ensure-restore, the forcing_available idiom from
    # generate_preview_job_test.rb. The ensure is load-bearing: a leaked override would make every
    # later test in this process see a broken intake.
    test "an intake failure does not fail a scan that already succeeded" do
      original = Maker::ProjectIntake.method(:for_user)
      Maker::ProjectIntake.define_singleton_method(:for_user) { |**| raise "intake exploded" }
      begin
        assert_nothing_raised { Library::ScanJob.perform_now(user_id: @user.id, root: @root) }
        assert @user.nodes.present.exists?(name: "panel.svg"),
               "the reconcile's work stands — it committed before the intake ran"
      ensure
        Maker::ProjectIntake.define_singleton_method(:for_user, original)
      end
    end
  end
```

**On `@folder.storage_path`:** in a share-backed deployment `ensure_library_folder!` goes through the port's `mkdir`, so the directory already exists on disk and the node carries a `storage_path`. The `mkdir_p` above is therefore usually a no-op — it is there so the test does not depend on that, and so it still reads correctly if the fixture's root is recreated. If `storage_path` comes back nil in your run, the setup is on the chunk branch of the test file; move this class under the share-backed one.

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/jobs/library/scan_job_test.rb
```

Expected: FAIL — `the intake runs AFTER the reconcile` fails with `Expected: [:reconcile, :intake] Actual: [:reconcile]`, because nothing calls the intake yet.

- [ ] **Step 3: Add the call**

In `app/jobs/library/scan_job.rb`, replace `#perform`:

```ruby
    def perform(user_id:, root: nil)
      user = User.find(user_id)

      # `new` + `call` rather than `.call`, which returns the instance only on success: holding
      # the observer means #unreadable_dirs is still reachable, and that is the whole reason
      # Task 5 exposed it (and Task 7 gave S3Observer the same method for the same caller — here).
      observer = root ? Library::Scanner.new(user, root:) : observer_for(user)
      observer.call
      warn_unreadable(observer, user)
      intake_project_folders(user)
    end
```

and add this private method:

```ruby
    # THE PROJECT-FOLDER INTAKE RUNS HERE, INLINE AND STRICTLY AFTER THE RECONCILE, and the
    # placement is a correctness constraint rather than a convenience.
    #
    # If the intake moves a file after the Scanner has captured its observations, the Reconciler
    # sees the node at its NEW path unobserved and the observation at the OLD path unclaimed, pairs
    # them by (content_hash, size) — best_pairing working exactly as designed — and re-points the
    # node BACK to the old path while the bytes sit at the new one. It self-heals on the next pass,
    # but in the window the node's storage_path has no bytes behind it and a download answers 404 --
    # the TERMINAL answer, not the retryable 503 (library_present? still reads true, so Share#download
    # raises NotFound, not FetchError). Corrected 2026-07-30 after the claim was driven.
    # Running here, in the same job, after observer.call, makes that overlap impossible instead of
    # merely unlikely. Maker::ProjectIntakeJob's own schedule declines on scannable backends for the
    # other half of this reason.
    #
    # A JOB ORCHESTRATING A MAKER SERVICE IS NOT the inversion .observer_for refuses. That objection
    # is about a FileLayer ADAPTER reaching up into the catalog layer; a job is the top level, and
    # this one already owns "what happens on a scan".
    #
    # RESCUED, AND NARROWLY SCOPED TO THIS CALL. The reconcile above is already committed — there is
    # no transaction (see Library::Reconciler's header) — so letting an intake bug fail this job
    # would tell an operator reading the failed-jobs table that the library did not index, when it
    # did. The rescue must NOT wrap observer.call: Scanner::UnsafeScan is the reconcile refusing, and
    # that failed-jobs row is the only way the refusal reaches anyone.
    def intake_project_folders(user)
      Maker::ProjectIntake.for_user(user:)
    rescue StandardError => e
      Rails.logger.error("Library::ScanJob: the reconcile SUCCEEDED but the project-folder " \
                         "intake failed for user #{user.id}: #{e.class}: #{e.message}")
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/jobs/library/scan_job_test.rb test/jobs/maker/project_intake_job_test.rb
```

Expected: PASS, both files.

- [ ] **Step 5: Commit**

```bash
git add app/jobs/library/scan_job.rb test/jobs/library/scan_job_test.rb
git commit -m "feat(scan): run the project-folder intake after the reconcile

Placement is a correctness constraint. A move made after the Scanner captured
its observations is paired back by (content_hash, size) — best_pairing working
as designed — leaving the node pointed at a path with no bytes until the next
pass, where a download answers 404 -- terminal, not the retryable 503. Running inline after observer.call makes
that overlap impossible rather than unlikely.

The rescue is scoped to this call only: the reconcile is already committed, so
an intake bug must not report a successful scan as failed — and UnsafeScan must
still propagate, since its failed-jobs row is how a refusal reaches an operator."
```

---

## Task 11: The eager nudge on both upload doors

**Files:**
- Modify: `app/controllers/files_controller.rb` (`#create` ~line 285, `#finalize_upload` ~line 335, plus a private helper)
- Test: `test/integration/web/project_folder_intake_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/project_folder_intake_test.rb`:

```ruby
require "test_helper"

module Web
  # A file uploaded INTO a project folder attaches and files itself in the same request, rather than
  # waiting for the next sweep — which would read as broken.
  #
  # BOTH DOORS, because they are different flows: chunk drives the two-phase presigned upload
  # (begin_upload/finalize_upload) and share drives a multipart POST to #create. s3 shares share's
  # port_writable branch.
  class ProjectFolderIntakeTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper # an upload enqueues a preview job; keep it recorded, not run
    PASSWORD = "correct horse battery staple".freeze

    class ShareTest < ProjectFolderIntakeTest
      setup do
        @root = Dir.mktmpdir("pfi-share")
        FileLayer.current = FileLayer::Share.new(root: @root)
        @user = User.create!(email: "pfi-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
        @project = @user.maker_projects.create!(name: "Desk Lamp")
        @folder = @project.ensure_library_folder!(@user)
      end

      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root && File.exist?(@root)
      end

      # `parent:` defaults to the project folder; pass nil to upload to the library root.
      def upload(name, content = "x", parent: @folder.node_id)
        path = File.join(Dir.tmpdir, name)
        File.binwrite(path, content)
        post files_path, params: { parent_node_id: parent,
                                   file: Rack::Test::UploadedFile.new(path, "application/octet-stream") }
      ensure
        FileUtils.rm_f(path)
      end

      test "a file uploaded into the project folder is attached and filed in the same request" do
        upload("panel.svg", "<svg/>")
        assert_response :redirect

        att = @project.file_attachments.sole
        node = @user.nodes.find_by!(node_id: att.node_id)
        assert_equal "vector", att.role
        assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name
      end

      test "a file uploaded to the library root is untouched" do
        upload("loose.svg", "<svg/>", parent: nil)
        assert_response :redirect
        assert_equal 0, @project.file_attachments.count
      end

      # BEST-EFFORT: the upload already succeeded, so a failing intake must not turn it into an
      # error (the same rule enqueue_preview follows immediately above it).
      #
      # Hand-rolled override — `stub` does not exist in this suite (minitest 6 dropped
      # minitest/mock). The ensure-restore is load-bearing: a leak would break every later test in
      # this process.
      test "an intake failure does not fail the upload" do
        original = Maker::ProjectIntake.method(:for_node)
        Maker::ProjectIntake.define_singleton_method(:for_node) { |**| raise "intake exploded" }
        begin
          upload("panel.svg", "<svg/>")
          assert_response :redirect
          assert @user.nodes.present.exists?(name: "panel.svg"), "the file is uploaded either way"
        ensure
          Maker::ProjectIntake.define_singleton_method(:for_node, original)
        end
      end
    end

    class ChunkTest < ProjectFolderIntakeTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "pfic-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
        @project = @user.maker_projects.create!(name: "Desk Lamp")
        @folder = @project.ensure_library_folder!(@user)
      end

      test "a two-phase upload into the project folder is attached and filed on finalize" do
        content = "<svg/>"
        hash = Digest::SHA256.hexdigest(content)
        post begin_upload_files_path, as: :json, params: {
          name: "panel.svg", size: content.bytesize, parent_node_id: @folder.node_id,
          manifest: [ { hash:, offset: 0, length: content.bytesize } ]
        }
        assert_response :success
        commit_id = response.parsed_body["commit_id"]
        # THREE ARGS: ChunkStore#put is (user_id, hash, bytes) — chunk storage is per-user, which is
        # what makes cross-user chunk access impossible (CLAUDE.md §8). A two-arg call raises
        # ArgumentError.
        Storage::ChunkStore.current.put(@user.id, hash, content)

        post finalize_upload_files_path, as: :json, params: { commit_id: }
        assert_response :success

        att = @project.file_attachments.sole
        node = @user.nodes.find_by!(node_id: att.node_id)
        assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/integration/web/project_folder_intake_test.rb
```

Expected: FAIL. `@project.file_attachments.sole` raises `ActiveRecord::RecordNotFound` — nothing attaches yet.

- [ ] **Step 3: Add the nudge to both doors**

In `app/controllers/files_controller.rb`, in `#create`, add one line after `enqueue_preview`:

```ruby
    enqueue_preview(node_id: info.node_id, name: upload.original_filename)
    intake_project_folder(info.node_id)
```

In `#finalize_upload`, add it to the existing conditional line:

```ruby
    node = current_user.nodes.find_by(node_id: version.node_id)
    if node
      enqueue_preview(node_id: version.node_id, name: node.name)
      intake_project_folder(version.node_id)
    end
```

(That replaces the trailing `if node` guard on the `enqueue_preview` line — keep the guard, just widen it to both calls.)

Then add the private helper beside `enqueue_preview`:

```ruby
  # THE EAGER NUDGE. A file uploaded into a project's folder attaches and files itself NOW rather
  # than at the next sweep, which would read as broken — the same "the nudge is the fast path and
  # the poll is the correctness fallback" shape the sync engine already uses. The periodic
  # Maker::ProjectIntake run is what makes it correct; this is what makes it feel instant.
  #
  # BEST-EFFORT, and rescued as widely as enqueue_preview above is, for the same reason: the upload
  # has ALREADY SUCCEEDED — the bytes are in the store and the node exists — so a failure here must
  # never turn a successful upload into an error the user sees. StandardError is right here, where
  # it is wrong inside the service: this rescue is protecting a response, not making a policy
  # decision, and the service has already narrowed every condition it understands.
  def intake_project_folder(node_id)
    node = current_user.nodes.present.find_by(node_id:)
    Maker::ProjectIntake.for_node(user: current_user, node:) if node&.file?
  rescue StandardError => e
    Rails.logger.warn("files#intake_project_folder(#{node_id}): #{e.class}: #{e.message}")
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/integration/web/project_folder_intake_test.rb
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/files_controller.rb test/integration/web/project_folder_intake_test.rb
git commit -m "feat(files): attach and file an upload into a project folder immediately

Both doors — the share/s3 multipart POST and chunk's finalize_upload — so the
verb means the same thing in each. Best-effort and rescued as widely as
enqueue_preview beside it: the upload already succeeded, so a failing intake
must not turn it into an error. The periodic run is what makes this correct;
this is what stops it reading as broken."
```

---

## Task 12: `rake projects:organize`

**Files:**
- Create: `lib/tasks/projects.rake`
- Test: none (the task is a thin printer over `ProjectIntake.for_user`, which Tasks 4–8 cover; the `Float::INFINITY` cap-lift is asserted in Step 3 by driving it)

- [ ] **Step 1: Write the task**

Create `lib/tasks/projects.rake`:

```ruby
namespace :projects do
  # DRY_RUN=1 follows the house idiom set by `previews:reap_dead_nodes` rather than the spec's
  # `projects:organize:dry_run` — surface-level, and consistency with the neighbouring tasks wins.
  desc "Attach + file every project folder's loose files (DRY_RUN=1 to report only)"
  task organize: :environment do
    dry = ENV["DRY_RUN"].present?

    # THE CAP IS LIFTED HERE, and that is the whole reason this task exists. The periodic run
    # refuses above PROJECT_ORGANIZE_MAX_MOVES because an implausible count is worth stopping for;
    # an operator running this by hand, having just read the dry run, is the deliberate action that
    # refusal is waiting for. Float::INFINITY rather than a flag: `count > Float::INFINITY` is
    # false for every count, so no branch has to learn a second meaning of "no cap".
    cap = Float::INFINITY

    totals = { attached: 0, moved: 0, skipped: 0 }
    User.find_each do |user|
      run = Maker::ProjectIntake.for_user(user:, dry_run: dry, cap:)
      run.results.each do |project, result|
        next if result.attached.zero? && result.moved.zero? && result.skipped.zero?

        puts "#{project.slug}: #{dry ? 'would attach' : 'attached'} #{result.attached}, " \
             "#{dry ? 'would file' : 'filed'} #{result.moved}, left #{result.skipped}"
        result.plan.each { |name, folder| puts "    #{name} -> #{folder}/" }
        totals[:attached] += result.attached
        totals[:moved] += result.moved
        totals[:skipped] += result.skipped
      end
    end

    puts "#{dry ? 'Would attach' : 'Attached'} #{totals[:attached]}, " \
         "#{dry ? 'would file' : 'filed'} #{totals[:moved]}, left #{totals[:skipped]}."
    puts "(dry run — nothing was written)" if dry
  end
end
```

- [ ] **Step 2: Drive the dry run against real data**

Create a project folder with two loose files in the dev DB, then:

```bash
DRY_RUN=1 bin/rails projects:organize
```

Expected output shape — per-project counts, a `name -> folder/` line per planned move, and the closing `(dry run — nothing was written)`. Confirm nothing changed:

```bash
bin/rails runner 'puts Maker::FileAttachment.count'
```

Expected: the same number as before the dry run.

- [ ] **Step 3: Drive the real run**

```bash
bin/rails projects:organize
bin/rails runner 'puts Maker::FileAttachment.count'
```

Expected: files are filed into subfolders and the attachment count has risen. Run it a second time — expected: no output rows (idempotent).

- [ ] **Step 4: Verify the cap really is lifted**

```bash
PROJECT_ORGANIZE_MAX_MOVES=1 bin/rails projects:organize
```

Expected: it still files everything — the task passes `cap: Float::INFINITY`, so the env var cannot refuse it. (Contrast: `PROJECT_ORGANIZE_MAX_MOVES=1 bin/rails runner 'Maker::ProjectIntakeJob.perform_now(user_id: User.first.id)'` logs the refusal.)

- [ ] **Step 5: Commit**

```bash
git add lib/tasks/projects.rake
git commit -m "feat(projects): rake projects:organize, with DRY_RUN=1

The deliberate-action door the periodic cap refusal is waiting for, so the cap
is lifted here — Float::INFINITY rather than a flag, so no branch learns a
second meaning of 'no cap'. DRY_RUN=1 matches previews:reap_dead_nodes rather
than the spec's :dry_run subtask; consistency with the neighbours wins."
```

---

## Task 13: Three-leg verification and the docs

**Files:**
- Modify: `CLAUDE.md` (§3 table row + §12 step 9)
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Run the full suite on all three legs**

```bash
bin/rails test 2>&1 | tail -5
```

```bash
LIBRARY_BACKEND=share bin/rails test 2>&1 | tail -5
```

```bash
LIBRARY_BACKEND=s3 bin/rails test 2>&1 | tail -5
```

Expected: **0 failures, 0 errors on all three, with identical run/assertion counts.** A leg that differs means a test depends on the ambient backend — which is exactly what this CI leg exists to catch. Record the actual counts; they go in the docs in Step 3.

- [ ] **Step 2: Run rubocop**

```bash
bin/rubocop app/services/maker/project_intake.rb app/services/maker/project_folders.rb app/jobs/maker/project_intake_job.rb app/jobs/library/scan_job.rb app/controllers/files_controller.rb lib/tasks/projects.rake
```

Expected: no offenses. Fix any that appear — do not add inline disables.

- [ ] **Step 3: Update `CLAUDE.md`**

Add a row to the §3 components table, after the **Library scan** row:

```markdown
| **Project intake** | `app/services/maker/project_intake.rb` | Makes the catalog agree with what is in a project's library folder: **attach** every live file in the `Projects/<slug>/` **subtree**, then **file** whatever is loose at its **root** into a category subfolder (`Maker::ProjectFolders`, keyed on a `Maker::FileAttachment` ROLE so there is no second extension table). **ROOT = INBOX is the whole sort rule, and it is STATELESS**: a file already in a subfolder is the user's filing — *including filing we would disagree with* — and position is what records that, so re-filing one would fight the user every 15 min (and on chunk, broadcast that fight to every device). **It is a SWEEP over `nodes`, not a hook on the write doors**, because there are SIX (`FilesController#create`, `#finalize_upload`, `Library::Reconciler`, `Sync::Commit#finalize`, `Addons::LibraryOutput`, `MoveNode`, trash restore) and no funnel — a seventh would silently skip the rule, which is this repo's most-repeated bug (see `AttachToProject`'s header; the five `port_writable?` copies). It **adds no new copy of that branch**: `MoveNode` moves and `LibraryFolder` mkdirs. **It READS `folder_node_id` and never calls `ensure_library_folder!`** — the ensure would make a *sweep* create `Projects/<slug>` for every folderless project, which is the side-effect bug `#relocate` shipped, at library scale. **It asks `AttachToProject#refusal_for` before every move**, which is why that method is public. **THE TRIGGER PLACEMENT IS A CORRECTNESS CONSTRAINT, not tidiness:** on share/s3 it runs INLINE at the end of `ScanJob#perform`, because a move made after the Scanner captured its observations gets paired back by `(content_hash, size)` — `best_pairing` working exactly as designed — leaving the node pointed at a path with **no bytes** until the next pass, where a download **404s** -- TERMINAL, not the retryable 503, since `library_present?` still reads true (corrected 2026-07-30 by driving it). `ProjectIntakeJob.sweep_all!` therefore **declines on `scannable?`** and only schedules chunk. **The cap is ABSOLUTE (500, `PROJECT_ORGANIZE_MAX_MOVES`, read per call) and RUN-scoped, and the Reconciler's percentage guard is the WRONG MODEL** — a percentage needs a denominator, the only honest one is "files at project roots", and the intended first run files **100%** of them, so it would guard against success. Over the cap **nothing moves and everything still attaches** (an attach writes a row and no bytes), and it **answers a status rather than raising**, because a raise would fail a `ScanJob` whose scan had already succeeded and committed. `rake projects:organize` (`DRY_RUN=1`) lifts the cap. |
```

Then append to §12 step 9's bullet list, after the `Maker::MoveNode` paragraph:

```markdown
     **THE `port_writable?` COUNT IS STILL FIVE** (2026-07-29). `Maker::ProjectIntake` and
     `Maker::ProjectFolders` add a sixth *caller* of the two-door services but **no sixth copy of
     the branch** — the intake moves through `MoveNode` and mkdirs through `LibraryFolder`, which
     is what the "a new one needs an argument for being inline" rule is for. **`ROLE_BY_EXT` gained
     a `laser` role** (`lbrn2` moved off `vector`, so a LightBurn program and an svg drawing can
     land in different folders) **and `nc`/`tap`/`ngc`** (CNC files previously had no role at all,
     so a CNC-heavy project was entirely "Other"). Both flow to the Files-page chips and the project
     panel headings through the existing `EXT_FAMILIES` derivation, with no second edit —
     `db/migrate/*_rederive_laser_roles.rb` backfilled the existing rows, and it is **NOT a copy of
     its two predecessors**: they moved rows out of `other` (new extensions), so they select
     `role: "other"` and roll back to it, while this one selects `vector` and must roll back to
     `vector` — copying either gives a silent no-op `up` and a `down` that leaves rows worse off
     than before.
```

- [ ] **Step 4: Update `docs/STATUS.md`**

Add an entry describing the arc, following the file's existing per-arc format: the branch name, the suite counts from Step 1 (all three legs), what shipped, and the three decisions most likely to be undone by a later editor — root-is-inbox being stateless, the ScanJob-ordering constraint, and the cap being absolute-and-run-scoped rather than a percentage. Note explicitly that **CI could not run** (only the macOS runner is registered; all seven `ci.yml` jobs target linux) and that verification was the three local legs.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/STATUS.md
git commit -m "docs: the project-folder intake

Records the three decisions most likely to be undone: root-is-inbox is
stateless (position IS the marker, so re-filing fights the user), the
ScanJob-ordering is a correctness constraint (a concurrent move is paired back
by content hash and the node points at a path with no bytes), and the cap is
absolute + run-scoped because a percentage would guard against success."
```

---

## Self-review

**Spec coverage.** Every section maps to a task: §3 vocabulary → Task 1 (+ Task 2, the departure); §4 `ProjectFolders` + totality → Task 3; §5 attach/file/subtree/`refusal_for`/lazy folders → Tasks 4–5, `.for_node` → Task 8, trigger + scan race → Tasks 9–11; §6 latency → no code (a property of Tasks 9–11); §7 first run, dry run, cap, summary logging → Tasks 7, 9, 12; §8 failure table → Tasks 5–6 (`Collision`/`NotFound`/`UnsupportedOperation` in `#place`, `FetchError` in `#file_all`, `InvalidName` deliberately unrescued); §9 tests → distributed, full three-leg run in Task 13; §10 boundary → the class header in Task 4 plus Task 13's docs.

**Departures, both flagged at the top:** the backfill migration is in (Task 2) rather than deferred, and the dry run is `DRY_RUN=1` rather than a subtask.

**Type consistency.** `Result = Data.define(:attached, :moved, :skipped, :plan, :status)` is constructed with all five members at every one of its four call sites in Tasks 4–5. `RunResult = Data.define(:results, :status, :inbox_total, :cap)` likewise, at both sites in Task 7. `for_project(user:, project:, dry_run:, move:)` keeps that signature in Tasks 4, 5, 7 and 8. `place` answers a folder-name String or nil throughout. `MAX_DEPTH` is shared by the down-walk (Task 4) and the up-walk (Task 8). `Maker::ProjectFolders.folder_for` is the only name used for the map lookup.

**Four defects were found by checking the codebase rather than by re-reading the plan, and they are recorded because the first one would have broken three tasks:**

1. **`Object#stub` does not exist in this suite** — minitest 6 dropped `minitest/mock`, and requiring it is a `LoadError` (recorded at `test/jobs/maker/generate_preview_job_test.rb:19`). The first draft used `.stub(` in Tasks 6, 10 and 11. All three now hand-roll a fake with `define_singleton_method` + an `ensure` restore, following `with_broken_move` (`test/integration/web/attach_auto_move_test.rb:39`) and `forcing_available`.
2. **`ChunkStore#put` is `(user_id, hash, bytes)`** — chunk storage is per-user, which is what makes cross-user access impossible (§8). Task 11's two-arg call would have raised `ArgumentError`.
3. **The fake backend in Task 6 needs the destination folder to already exist**, or `ensure_path!` reaches its absent `mkdir` and the test passes for the wrong reason (`NoMethodError`, not `FetchError`). Hence `seed_folder`.
4. **Cumulative test counts were miscounted twice while drafting.** The per-file "PASS, N tests" literals on `project_intake_test.rb` are gone rather than corrected — the file grows across Tasks 4–8, so a stale literal reads as a failure.

**Testing constraint that applies to every task:** fakes are hand-rolled with `define_singleton_method` and restored in an `ensure`. A leaked override makes later tests in the same process see a broken collaborator, which is why every override in this plan is wrapped.

**One thing the plan deliberately does NOT do:** `Maker::AttachToProject` is untouched. The intake calls `#refusal_for` and nothing else, so the attach flow's own behaviour — including its move into the project folder *root*, which this then files one step further — is unchanged. That means an attach on chunk emits two changelog `move` entries where one would do. Left alone on purpose: collapsing them means teaching `AttachToProject` the folder map, which widens its contract for a saving no user can perceive.
