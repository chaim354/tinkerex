# Project Files By Type Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split a project's Files panel into headed sub-sections grouped by file type, and teach the role vocabulary about laser and CAD-source files so they stop landing in "Other".

**Architecture:** Grouping is `group_by(&:role)` over attachments the controller already loads — no new query and no new column. The role vocabulary gains two values (`vector`, `cad_source`), which needs one self-contained data migration to re-derive rows currently marked `other`. Display labels live on the model as an ordered constant that `ROLES` is derived *from*, so a heading can never name a role that doesn't exist.

**Tech Stack:** Rails 8.1, ERB views, Minitest.

**Spec:** `docs/superpowers/specs/2026-07-27-project-page-overhaul-design.md` §4.

---

## File Structure

| File | Change | Responsibility after this plan |
|---|---|---|
| `app/models/maker/file_attachment.rb` | Modify | Owns the role vocabulary: `ROLE_LABELS` (ordered, display order) is the source of truth; `ROLES` derives from its keys. `ROLE_BY_EXT` gains six extensions. |
| `db/migrate/*_rederive_vector_and_cad_source_roles.rb` | Create | One-shot, self-contained: moves `other` rows whose filename now maps to `vector`/`cad_source`. |
| `app/views/projects/_attachments.html.erb` | Modify | Renders one section per non-empty role, in `ROLE_LABELS` order. Per-tile role badge removed. |
| `app/assets/stylesheets/projects.css` | Modify | Adds `.attachment-group` / `.attachment-group-head`. |
| `test/models/maker/file_attachment_test.rb` | Modify | Covers the two new roles and the `ROLES`/`ROLE_LABELS` invariant. |
| `test/models/maker/rederive_roles_migration_test.rb` | Create | Drives the migration class directly. |
| `test/integration/web/project_attachments_test.rb` | Modify | Covers the grouped rendering. |

---

## Task 1: Two new roles in the vocabulary

**Files:**
- Modify: `app/models/maker/file_attachment.rb:8-19`
- Test: `test/models/maker/file_attachment_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `module Maker` / `class FileAttachmentTest` in
`test/models/maker/file_attachment_test.rb`:

```ruby
    test "laser and vector extensions derive the vector role" do
      assert_equal "vector", Maker::FileAttachment.role_for("panel.svg")
      assert_equal "vector", Maker::FileAttachment.role_for("Panel.DXF")
      assert_equal "vector", Maker::FileAttachment.role_for("cut file.lbrn2")
    end

    test "CAD source extensions derive the cad_source role" do
      assert_equal "cad_source", Maker::FileAttachment.role_for("box.scad")
      assert_equal "cad_source", Maker::FileAttachment.role_for("Bracket.f3d")
      assert_equal "cad_source", Maker::FileAttachment.role_for("frame.FCStd")
      assert_equal "cad_source", Maker::FileAttachment.role_for("mount.sldprt")
      assert_equal "cad_source", Maker::FileAttachment.role_for("Rig.SLDASM")
    end

    test "the existing derivations are unchanged" do
      assert_equal "model", Maker::FileAttachment.role_for("bracket.stl")
      assert_equal "image", Maker::FileAttachment.role_for("photo.jpg")
      assert_equal "instructions", Maker::FileAttachment.role_for("manual.pdf")
      assert_equal "gcode", Maker::FileAttachment.role_for("print.gcode")
      assert_equal "source_archive", Maker::FileAttachment.role_for("bundle.zip")
      assert_equal "other", Maker::FileAttachment.role_for("readme.txt")
      assert_equal "other", Maker::FileAttachment.role_for("no-extension")
    end

    # Pinned independently of ROLE_LABELS on purpose. Asserting ROLES == ROLE_LABELS.keys would be
    # TAUTOLOGICAL — ROLES is DEFINED as those keys — so it could not catch a typo'd key like
    # "cad_soruce", which is exactly the failure a reader assumes it guards. This literal can.
    test "the role vocabulary is exactly these eight values" do
      assert_equal %w[cad_source gcode image instructions model other source_archive vector],
                   Maker::FileAttachment::ROLES.sort
    end

    test "the two new roles are accepted by the validation" do
      %w[vector cad_source].each do |role|
        att = @item.file_attachments.build(user: @user, node_id: "n", role:)
        assert att.valid?, "expected #{role} to be a valid role"
      end
    end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/models/maker/file_attachment_test.rb
```

Expected: FAIL — `role_for("panel.svg")` returns `"other"`, and
`Maker::FileAttachment::ROLE_LABELS` raises `NameError`.

- [ ] **Step 3: Rewrite the vocabulary**

In `app/models/maker/file_attachment.rb`, replace lines 8-19 (the `ROLES`, `ROLE_BY_EXT` and
`role_for` block) with:

```ruby
    # Display order AND the source of truth for the vocabulary — the Files panel renders one
    # section per key, in this order, using these labels. ROLES derives from the keys so a
    # heading can never name a role the validation would reject.
    ROLE_LABELS = {
      "model"          => "Models",
      "image"          => "Images",
      "instructions"   => "Instructions",
      "vector"         => "Vector",
      "cad_source"     => "CAD source",
      "gcode"          => "G-code",
      "source_archive" => "Archives",
      "other"          => "Other"
    }.freeze

    ROLES = ROLE_LABELS.keys.freeze

    ROLE_BY_EXT = {
      "stl" => "model", "3mf" => "model", "obj" => "model", "step" => "model", "stp" => "model",
      "png" => "image", "jpg" => "image", "jpeg" => "image", "gif" => "image", "webp" => "image", "bmp" => "image",
      "pdf" => "instructions", "gcode" => "gcode", "gco" => "gcode", "zip" => "source_archive",
      # Laser / 2D vector work. Without these a laser-heavy project is mostly "Other".
      "svg" => "vector", "dxf" => "vector", "lbrn2" => "vector",
      # Editable CAD sources, as opposed to the exported meshes above. SolidWorks sits with Fusion
      # here because CLAUDE.md §1 and docs/research-format-processing.md treat them as one category
      # — proprietary, no FOSS parser, you open them in the tool that made them.
      "scad" => "cad_source", "f3d" => "cad_source", "fcstd" => "cad_source",
      "sldprt" => "cad_source", "sldasm" => "cad_source"
    }.freeze

    # Best-effort role from a filename's extension; unknown -> "other".
    def self.role_for(name)
      ROLE_BY_EXT.fetch(File.extname(name.to_s).downcase.delete("."), "other")
    end
```

Note `step`/`stp` deliberately stay `model` — they are the interchange export a slicer reads, and
moving them would recategorize existing attachments this migration is not supposed to touch.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/models/maker/file_attachment_test.rb
```

Expected: PASS.

- [ ] **Step 5: Confirm nothing depended on the old ROLES ordering**

```bash
grep -rn "ROLES" app/ test/ --include="*.rb" --include="*.erb" | grep -i "attachment"
```

Expected: only the model definition, the validation, and a comment in
`app/services/maker/attach_to_project.rb`. Nothing iterates `ROLES` to build a select or a
serializer, so reordering it is safe.

- [ ] **Step 6: Commit**

```bash
git add app/models/maker/file_attachment.rb test/models/maker/file_attachment_test.rb
git commit -m "feat(attachments): add vector and cad_source roles"
```

---

## Task 2: Re-derive existing `other` attachments

**Files:**
- Create: `db/migrate/<timestamp>_rederive_vector_and_cad_source_roles.rb`
- Create: `test/models/maker/rederive_roles_migration_test.rb`

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration RederiveVectorAndCadSourceRoles
```

This creates `db/migrate/<timestamp>_rederive_vector_and_cad_source_roles.rb`. The exact timestamp
does not matter — the test below finds the file by glob.

> **Expect the whole suite to refuse to run from this moment until you migrate.** `rails/test_help`
> calls `maintain_test_schema!`, which raises a pending-migration error for *every* test as soon as
> an unapplied migration file exists on disk — before any test code runs. So run
> `bin/rails db:migrate` once now, against the still-empty generated migration, to clear the gate.
> That run bumps only `db/schema.rb`'s version line. Step 3's "watch it fail" then fails on real
> assertions rather than on the schema check, which is the point — a pending-migration error is not
> the red you are looking for.

- [ ] **Step 2: Write the failing test**

Create `test/models/maker/rederive_roles_migration_test.rb`:

```ruby
require "test_helper"
require Dir[Rails.root.join("db/migrate/*_rederive_vector_and_cad_source_roles.rb")].first

class RederiveRolesMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rederive@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
  end

  # node_id has no FK — the filename lives on the node, so the migration has to join to find it.
  def attach(name, role)
    @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file")
    @project.file_attachments.create!(user: @user, node_id: "n-#{name}", role:)
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages do
      RederiveVectorAndCadSourceRoles.new.up
    end
  end

  test "an 'other' dxf becomes vector and an 'other' scad becomes cad_source" do
    dxf  = attach("panel.dxf", "other")
    scad = attach("box.scad", "other")
    # SolidWorks travels with Fusion — if this list ever drifts from ROLE_BY_EXT, closing the gap
    # after this migration has run needs a whole second migration, so it is pinned here too.
    sld  = attach("mount.sldprt", "other")

    run_migration

    assert_equal "vector", dxf.reload.role
    assert_equal "cad_source", scad.reload.role
    assert_equal "cad_source", sld.reload.role
  end

  test "a role set deliberately by the importer is never re-derived" do
    # A PDF the model-library importer marked `instructions`; also a .dxf someone filed as
    # `instructions` on purpose. Neither is "other", so neither is touched.
    pdf = attach("manual.pdf", "instructions")
    odd = attach("diagram.dxf", "instructions")

    run_migration

    assert_equal "instructions", pdf.reload.role
    assert_equal "instructions", odd.reload.role
  end

  test "an 'other' row with no new mapping stays other" do
    txt = attach("readme.txt", "other")
    run_migration
    assert_equal "other", txt.reload.role
  end

  test "an attachment whose node is missing is left alone rather than raising" do
    orphan = @project.file_attachments.create!(user: @user, node_id: "gone", role: "other")
    assert_nothing_raised { run_migration }
    assert_equal "other", orphan.reload.role
  end

  test "down returns the new roles to other" do
    dxf = attach("panel.dxf", "other")
    run_migration
    assert_equal "vector", dxf.reload.role

    ActiveRecord::Migration.suppress_messages { RederiveVectorAndCadSourceRoles.new.down }
    assert_equal "other", dxf.reload.role
  end

  # Safety under re-run is the property a migration most deserves an explicit assertion for — a real
  # `db:migrate` can be interrupted and re-invoked.
  test "running up twice is a no-op the second time" do
    dxf = attach("panel.dxf", "other")
    txt = attach("readme.txt", "other")

    run_migration
    run_migration

    assert_equal "vector", dxf.reload.role
    assert_equal "other", txt.reload.role
  end

  # The migration deliberately COPIES its extension list rather than referencing ROLE_BY_EXT, so the
  # two can silently drift. This is the only thing that would notice — and it lives in the test
  # suite, so the migration itself still executes with zero app-model dependency.
  test "the migration's extension list still agrees with the model's" do
    RederiveVectorAndCadSourceRoles::NEW_ROLE_BY_EXT.each do |ext, role|
      assert_equal role, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "migration maps #{ext} to #{role}, model disagrees"
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

```bash
bin/rails test test/models/maker/rederive_roles_migration_test.rb
```

Expected: FAIL — the generated migration is an empty `change` method, so nothing is re-derived
(`assert_equal "vector"` gets `"other"`).

- [ ] **Step 4: Write the migration**

Replace the generated file's contents with:

```ruby
# Moves attachments that were "other" only because ROLE_BY_EXT had no entry for their extension
# into the two roles added alongside this migration.
#
# SELF-CONTAINED ON PURPOSE. It does not call Maker::FileAttachment.role_for and does not use the
# app's models: a data migration runs against whatever the schema and the code look like months
# from now, and app code keeps moving. The six extensions below are exactly the ones ROLE_BY_EXT
# gains in this change, which is also what makes `down` exact — before this, no row could hold
# either role, so every row holding one now was put there by `up`.
class RederiveVectorAndCadSourceRoles < ActiveRecord::Migration[8.1]
  # Must stay in step with the extensions ROLE_BY_EXT gains in Task 1 — including `sldprt`/`sldasm`,
  # which were added there after review. This list is deliberately a COPY rather than a reference to
  # `ROLE_BY_EXT` (a data migration must not depend on app code that keeps moving), and the cost of
  # that choice is exactly this: an extension added to the model *after* this migration runs will
  # never re-derive the rows already sitting in `other`, and closing that needs a SECOND migration.
  #
  # `down` returns EVERY vector/cad_source row to "other", not only the rows `up` moved — it has no
  # record of which those were. That is exact only until the first attachment is created directly
  # with one of these roles, which `role_for` does at upload/attach time in four controllers; that
  # code ships in Task 1, so the window can close before `up` ever runs — NOT "once the UI ships".
  # Acceptable because the pair is self-healing: re-running `up` re-derives migrated and organic
  # rows identically, since the mapping is a pure function of the current filename.
  NEW_ROLE_BY_EXT = {
    "svg" => "vector", "dxf" => "vector", "lbrn2" => "vector",
    "scad" => "cad_source", "f3d" => "cad_source", "fcstd" => "cad_source",
    "sldprt" => "cad_source", "sldasm" => "cad_source"
  }.freeze

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    moved = 0
    MigrationAttachment.where(role: "other").find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil? # attachment to a deleted/missing node — nothing to derive from
      ext = File.extname(node.name.to_s).downcase.delete(".")
      new_role = NEW_ROLE_BY_EXT[ext]
      next if new_role.nil?
      att.update_columns(role: new_role)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  def down
    MigrationAttachment.where(role: NEW_ROLE_BY_EXT.values.uniq).update_all(role: "other")
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/models/maker/rederive_roles_migration_test.rb
```

Expected: PASS, 7 tests.

> **Knowingly deferred here, with reasons — do not treat these as oversights.** (1) No test asserts
> the `say "re-derived N…"` count; the arithmetic is trivially correct by inspection and asserting
> on log text couples a test to output formatting. (2) `up` does one `find_by` per row — measured at
> ~2 SQL statements and ~0.73 ms per attachment, so ~35-40s at a 50k-row backlog this single-user
> deployment does not have. Batch it (pluck + one `update_all` per role, mirroring `down`) if this
> shape is ever reused on a bigger table. (3) No incremental progress output, for the same reason.

- [ ] **Step 6: Apply the migration and check the schema is unchanged**

```bash
bin/rails db:migrate && git diff --stat db/schema.rb
```

Expected: `db/schema.rb` shows only the version bump — this migration touches data, not structure.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb test/models/maker/rederive_roles_migration_test.rb
git commit -m "feat(attachments): re-derive 'other' roles into vector and cad_source"
```

---

## Task 3: Group the Files panel

**Files:**
- Modify: `app/views/projects/_attachments.html.erb:18-49`
- Modify: `app/assets/stylesheets/projects.css:44-49`
- Test: `test/integration/web/project_attachments_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/web/project_attachments_test.rb`, inside `module Web` /
`class ProjectAttachmentsTest`. That file already defines the `sign_in` helper, the
`pin_file_layer_backend("chunk")` setup, and an `attach_node(user, project, name:, node_id:,
role:)` helper — use them rather than adding new ones.

```ruby
    test "the files panel groups attachments by type and omits empty categories" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      attach_node(user, project, name: "bracket.stl", node_id: "n-1", role: "model")
      attach_node(user, project, name: "shade.stl",   node_id: "n-2", role: "model")
      attach_node(user, project, name: "photo.jpg",   node_id: "n-3", role: "image")
      attach_node(user, project, name: "panel.dxf",   node_id: "n-4", role: "vector")

      get project_path(project)
      assert_response :success

      # One section per non-empty role, in ROLE_LABELS order.
      assert_select ".attachment-group", count: 3
      assert_select ".attachment-group-head", text: /Models/
      assert_select ".attachment-group-head", text: /Images/
      assert_select ".attachment-group-head", text: /Vector/
      # Empty categories are not rendered at all.
      assert_select ".attachment-group-head", text: /G-code/, count: 0
      assert_select ".attachment-group-head", text: /Archives/, count: 0

      # Headings carry the count, and the per-tile role badge is gone.
      assert_select ".attachment-group-head", text: /Models \(2\)/
      assert_select ".attachment-tile .badge", count: 0
    end

    test "an attachment whose node is gone still renders in its category" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.file_attachments.create!(user:, node_id: "vanished", role: "model",
                                       label: "bracket.stl")

      get project_path(project)
      assert_select ".attachment-group-head", text: /Models \(1\)/
      assert_select ".attachment-tile.unavailable .grid-name", text: "bracket.stl"
    end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/integration/web/project_attachments_test.rb -n "/groups attachments|node is gone/"
```

Expected: FAIL — `.attachment-group` does not exist; the panel is one flat `.attachments-grid`.

- [ ] **Step 3: Rewrite the panel**

Replace `app/views/projects/_attachments.html.erb` in full:

```erb
<%#
  Attached design files, grouped by role into headed sections in ROLE_LABELS order. `@att_nodes`
  (node_id => Node) is the source of truth for name + availability — a DB fact, independent of the
  file backend. `@thumbs` (ThumbnailMap) is best-effort. A node not in @att_nodes (deleted/missing)
  renders as an unavailable placeholder, never a broken image or a 500.

  ONE `thumbs` controller wraps every group rather than one per grid: Stimulus finds targets
  anywhere in the controller element's subtree, so a single instance polls all pending cells on the
  page instead of N instances polling their own slice.
%>
<section class="panel attachments-panel">
  <div class="panel-head">
    <h2>Files</h2>
    <div class="panel-actions">
      <%= link_to "Attach existing", new_project_attachment_path(@project), class: "linkbtn" %>
      <%= render "upload_control", upload_url: project_uploads_path(@project),
                 attach_url: project_attachments_path(@project), redirect_url: project_path(@project),
                 parent_node_id: @upload_parent_node_id %>
    </div>
  </div>

  <% if @attachments.empty? %>
    <p class="muted">No files attached yet.</p>
  <% else %>
    <% grouped = @attachments.group_by(&:role) %>
    <div data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
      <% Maker::FileAttachment::ROLE_LABELS.each do |role, label| %>
        <% group = grouped[role] %>
        <% next if group.blank? %>
        <section class="attachment-group">
          <h3 class="attachment-group-head"><%= label %> <span class="muted">(<%= group.size %>)</span></h3>
          <div class="attachments-grid">
            <% group.each do |att| %>
              <% node = @att_nodes[att.node_id] %>
              <% if node %>
                <% ext = File.extname(node.name).delete(".").upcase.first(4) %>
                <div class="attachment-tile">
                  <%= link_to file_path(att.node_id), class: "grid-card file-cell",
                              data: { thumbs_target: "cell", node_id: att.node_id, ext: ext } do %>
                    <%= render "files/thumb", thumb: @thumbs.thumb(att.node_id), ext_label: ext %>
                    <span class="grid-name"><%= node.name %></span>
                  <% end %>
                  <div class="tile-meta">
                    <%= button_to "Detach", attachment_path(att), method: :delete, class: "linkbtn danger",
                                  form: { data: { turbo_confirm: "Detach #{node.name}? (the file itself is kept)" } } %>
                  </div>
                </div>
              <% else %>
                <div class="attachment-tile unavailable">
                  <span class="thumb">⚠️</span>
                  <span class="grid-name"><%= att.label.presence || "(file unavailable)" %></span>
                  <div class="tile-meta">
                    <%= button_to "Remove", attachment_path(att), method: :delete, class: "linkbtn danger" %>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </section>
      <% end %>
    </div>
  <% end %>
</section>
```

The role badge (`<span class="badge role-…">`) is gone from `.tile-meta` — the section heading says
what it said, and no stylesheet ever targeted `.badge.role-*`, so nothing is orphaned.

- [ ] **Step 4: Add the group styles**

In `app/assets/stylesheets/projects.css`, after the `.tile-meta` rule (line 49), add:

```css
.attachment-group { margin-bottom: 20px; }
.attachment-group:last-child { margin-bottom: 0; }
.attachment-group-head { font-size: 12px; font-weight: 700; color: var(--muted);
                         text-transform: uppercase; letter-spacing: 0.04em; margin: 0 0 10px; }
```

And change `.tile-meta` (line 49) — with the badge gone it holds a single button, so
`space-between` would pin it hard left:

```css
.tile-meta { display: flex; align-items: center; justify-content: center; }
```

- [ ] **Step 4b: Amend the pre-existing test that asserts the removed badge**

`"attached files render as tiles linking to the file view"`, already in
`test/integration/web/project_attachments_test.rb`, asserts
`assert_select ".attachment-tile .badge", text: /model/` — the exact element Step 3 removes. Delete
**only that assertion line**; the rest of the test (the tile renders, it links to the file view) is
still valid and must stay.

Verified during execution: that is the *only* place in the whole suite asserting on the per-tile
badge (checked all of `test/`, including `test/system/`). Without this step, Step 5's "Expected:
PASS, whole file" is unreachable.

> **This is the second plan in this set to miss a pre-existing test asserting the behaviour it
> removes** (the first was the status-UI plan's Step 5b). The authoring lesson: when a step deletes
> a rendered element, grep the suite for that element's selector *while writing the plan* — the new
> tests get written carefully and the old ones get forgotten, every time.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/integration/web/project_attachments_test.rb
```

Expected: PASS, whole file.

- [ ] **Step 6: Commit**

```bash
git add app/views/projects/_attachments.html.erb app/assets/stylesheets/projects.css \
        test/integration/web/project_attachments_test.rb
git commit -m "feat(projects): group the files panel into typed sections"
```

---

## Task 4: Full-suite verification on all three backend legs

**Files:** none — verification only.

- [ ] **Step 1: Default (chunk) leg**

```bash
bin/rails test
```

Expected: 0 failures, 0 errors. `attach_model_bundle_test.rb` and `models_import_test.rb` both
assert on roles set by the importer and must stay green — a failure there means Task 1 changed a
derivation it shouldn't have.

- [ ] **Step 2: Share leg**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test
```

Expected: identical counts to step 1.

- [ ] **Step 3: S3 leg**

```bash
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 \
  LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library \
  bin/rails test
```

Expected: identical counts to step 1.

> **The env vars are required, not decoration.** `LIBRARY_BACKEND=share` without `LIBRARY_PATH`
> aborts at boot (`LibraryBackendCheck::Error`) and fails ~195 tests for that one reason, which
> reads exactly like a catastrophic regression. `s3` needs the five `LIBRARY_S3_*` vars for the
> same reason. Both sets are lifted from `.github/workflows/ci.yml`'s `test-share-backend` /
> `test-s3-backend` jobs; the s3 values are deliberate stubs — the guard checks config *presence*,
> never the network, so no bucket is contacted and none needs to exist.

- [ ] **Step 4: Commit any incidental fixes**

Only if steps 1-3 required changes:

```bash
git add -A && git commit -m "test: fix fallout from typed attachment groups"
```
