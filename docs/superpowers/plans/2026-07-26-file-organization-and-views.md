# File Organization and Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Files web UI organizable — a project dropdown instead of a button per project, files that follow their project into its folder, sortable columns, and a flat "all my .stl files" view.

**Architecture:** All changes live in the web layer (`FilesController`, `Projects::AttachmentsController`, `app/views/files/`, `app/views/projects/`). The one new service, `Maker::MoveNode`, is the third appearance of a two-door backend branch (`port_writable?` → `FileLayer.current.move`; else → `Sync::Mutation.apply(op: "move")`) and is written to mirror the existing `Maker::LibraryFolder`. No migration, no adapter change, nothing in `Sync::*` or `FileLayer::*` is modified — the maker/file-layer split's §10 tripwire stays un-tripped.

**Tech Stack:** Rails 8, ERB views, Minitest integration tests, plain CSS (no build step), no new JS.

**Spec:** `docs/superpowers/specs/2026-07-26-file-organization-and-views-design.md`

---

## Background an engineer needs before starting

**Three backends, one suite, run three times.** `LIBRARY_BACKEND` selects the file layer: `chunk` (the sync engine's content-addressed store — the default in production), `share` (a mounted NAS directory), `s3` (the user's own bucket). Every test must pass on all three legs:

```bash
bin/rails test
LIBRARY_BACKEND=share bin/rails test
LIBRARY_BACKEND=s3 bin/rails test
```

Tests either seed bare `nodes` rows and stay backend-neutral (see `test/integration/web/folder_nav_test.rb`'s header comment), or pin a backend with `pin_file_layer_backend("chunk")` (defined in `test/test_helper.rb:52`). Prefer backend-neutral.

**The two doors.** Chunk mode's catalog is the sync engine's changelog, so a chunk-mode move is `Sync::Mutation.apply(user:, node:, op: "move")` plus a `LibraryChannel.broadcast_change`. Share/S3 own real bytes, so their move is `FileLayer.current.move`, which renames the file AND updates the node row. `FileLayer.current.capabilities.port_writable?` is how you tell them apart. Read `app/services/maker/library_folder.rb` before Task 1 — `Maker::MoveNode` is its sibling and must read like it.

**`Projects::AttachmentsController#set_project` resolves by SLUG:** `current_user.maker_projects.find_by!(slug: params[:project_id])`. Anywhere a project id travels in a param for this controller, it is the **slug**, not the integer id.

**`FileInfo#mtime` is unix NANOSECONDS.** Reading it as seconds is a bug this codebase has shipped twice.

---

## File structure

| File | Responsibility |
|---|---|
| `app/services/maker/move_node.rb` | **new** — the two-door move + collision detection + suggested-name generation |
| `app/controllers/concerns/move_conflicts.rb` | **new** — resolve `?move_conflict=<id>` into everything the prompt partial needs |
| `app/views/shared/_move_conflict.html.erb` | **new** — the collision `<dialog>`, rendered on the file page and the project page |
| `app/helpers/files_helper.rb` | **new** — sortable column headers + the extension-chip families |
| `app/controllers/files_controller.rb` | sort resolution, ext filter, flat mode, folder paths, attach ivars |
| `app/controllers/projects/attachments_controller.rb` | dedupe guard, auto-move, `#relocate` |
| `app/controllers/projects_controller.rb` | set `@move_conflict` on `#show` |
| `app/views/files/show.html.erb` | attach dropdown + already-attached chips + conflict dialog |
| `app/views/files/index.html.erb` | chip row, grid sort control, truncation notice |
| `app/views/files/_list.html.erb` | sortable headers, Folder column in flat mode |
| `app/views/files/_ext_filter.html.erb` | **new** — the extension chip row + "or an extension" input |
| `app/views/projects/show.html.erb` | render the conflict dialog |
| `config/routes.rb` | `POST /attachments`, `POST /projects/:project_id/attachments/relocate` |
| `app/assets/stylesheets/application.css` | chips, sortable headers, dialog, sort form |
| `app/assets/stylesheets/projects.css` | attach form + project chips |

Tests: `test/services/maker/move_node_test.rb`, `test/integration/web/files_sort_test.rb`, `test/integration/web/files_type_filter_test.rb`, `test/integration/web/attach_auto_move_test.rb`, plus additions to `test/integration/web/attach_from_files_test.rb`.

---

## Task 0: Capture the baseline

**Files:** none.

- [ ] **Step 1: Record the current test counts on all three legs**

```bash
bin/rails test 2>&1 | tail -3
LIBRARY_BACKEND=share bin/rails test 2>&1 | tail -3
LIBRARY_BACKEND=s3 bin/rails test 2>&1 | tail -3
```

Expected: three identical `N runs, M assertions, 0 failures, 0 errors, S skips` lines. **Write the number N down** — Task 8 compares against it. If the three legs disagree or anything is red before you have changed a line, STOP and report it; do not start building on a red baseline.

---

## Task 1: `Maker::MoveNode` — the two-door move

**Files:**
- Create: `app/services/maker/move_node.rb`
- Test: `test/services/maker/move_node_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/move_node_test.rb`:

```ruby
require "test_helper"

module Maker
  # The two-door move, one test class per door — the same shape as library_folder_test.rb, and for
  # the same reason: the branch IS the thing under test, so a single ambient-backend run would
  # exercise whichever door CI happened to pick and call the other one covered.
  class MoveNodeTest < ActiveSupport::TestCase
    # Chunk branch: the sync engine owns the tree, so a move must appear in the changelog.
    class ChunkBranch < MoveNodeTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "mn-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
        @dest = @user.nodes.create!(node_id: "dir-dest", name: "desk-lamp", kind: "dir")
        @node = @user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      end

      test "moves the node into the destination via the sync engine, keeping its node_id" do
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")

        @node.reload
        assert_equal "dir-dest", @node.parent_node_id
        assert_equal "bracket.stl", @node.name
        assert_equal "f-1", @node.node_id, "node_id must survive a move — attachments point at it"
        assert @user.changelog_entries.exists?(op: "move", node_id: "f-1"),
               "chunk-mode move must go through the sync engine (a changelog entry)"
      end

      test "renames when new_name is given" do
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest",
                             new_name: "bracket (2).stl")
        assert_equal "bracket (2).stl", @node.reload.name
      end

      test "raises Collision when a live sibling already holds the name" do
        @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest")

        assert_raises(Maker::MoveNode::Collision) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        end
        assert_nil @node.reload.parent_node_id, "a refused move must not have moved anything"
      end

      test "a tombstoned sibling is not a collision" do
        @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest", deleted: true)
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        assert_equal "dir-dest", @node.reload.parent_node_id
      end

      test "moving a node onto its own current name in its own folder is not a collision" do
        @node.update!(parent_node_id: "dir-dest")
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        assert_equal "dir-dest", @node.reload.parent_node_id
      end

      test "rejects a name that is not a leaf" do
        assert_raises(ArgumentError) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest",
                               new_name: "../escape.stl")
        end
      end

      test "available_name suggests the first free (n) variant" do
        @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest")
        assert_equal "bracket (2).stl",
                     Maker::MoveNode.available_name(@user, parent_node_id: "dir-dest",
                                                    name: "bracket.stl")

        @user.nodes.create!(node_id: "f-3", name: "bracket (2).stl", kind: "file",
                            parent_node_id: "dir-dest")
        assert_equal "bracket (3).stl",
                     Maker::MoveNode.available_name(@user, parent_node_id: "dir-dest",
                                                    name: "bracket.stl")
      end

      test "available_name returns nil when every variant is taken" do
        (2..10).each do |i|
          @user.nodes.create!(node_id: "t-#{i}", name: "bracket (#{i}).stl", kind: "file",
                              parent_node_id: "dir-dest")
        end
        @user.nodes.create!(node_id: "t-1", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest")
        assert_nil Maker::MoveNode.available_name(@user, parent_node_id: "dir-dest",
                                                  name: "bracket.stl")
      end
    end

    # Share branch: port_writable → FileLayer.current.move, which renames the real file AND
    # updates the node row. Exercises the same code path s3 takes.
    class ShareBranch < MoveNodeTest
      setup do
        @root = Dir.mktmpdir("mn-share")
        FileLayer.current = FileLayer::Share.new(root: @root)
        @user = User.create!(email: "mns-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
        FileUtils.mkdir_p(File.join(@root, "desk-lamp"))
        File.binwrite(File.join(@root, "bracket.stl"), "solid\n")
        @dest = @user.nodes.create!(node_id: "dir-dest", name: "desk-lamp", kind: "dir",
                                    storage_path: "desk-lamp")
        @node = @user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file",
                                    storage_path: "bracket.stl", size: 6)
      end
      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root && File.exist?(@root)
      end

      test "moves the real file through the port and keeps the node_id" do
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")

        assert File.exist?(File.join(@root, "desk-lamp", "bracket.stl")),
               "the bytes must actually move on a share"
        refute File.exist?(File.join(@root, "bracket.stl"))
        @node.reload
        assert_equal "desk-lamp/bracket.stl", @node.storage_path
        assert_equal "dir-dest", @node.parent_node_id
        assert_equal "f-1", @node.node_id
        assert_empty @user.changelog_entries.where(op: "move"),
                     "a share library has no changelog — the port is the whole move"
      end

      test "raises Collision before touching the disk when the name is taken" do
        File.binwrite(File.join(@root, "desk-lamp", "bracket.stl"), "other\n")
        @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest", storage_path: "desk-lamp/bracket.stl")

        assert_raises(Maker::MoveNode::Collision) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        end
        assert_equal "other\n", File.read(File.join(@root, "desk-lamp", "bracket.stl")),
                     "the existing file must be untouched"
        assert File.exist?(File.join(@root, "bracket.stl")), "the source must be untouched"
      end
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/maker/move_node_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Maker::MoveNode`.

- [ ] **Step 3: Write the service**

Create `app/services/maker/move_node.rb`:

```ruby
module Maker
  # Move a library node to a new parent (optionally under a new name), whichever way THIS
  # deployment holds its bytes.
  #
  # THE ONE PLACE the cross-backend move branch lives — the sibling of Maker::LibraryFolder, and
  # written to be read next to it:
  #   port_writable? (share/s3) → FileLayer.current.move — renames the real file/object AND
  #                               updates the node row (see FileLayer::Share#move).
  #   else            (chunk)   → Sync::Mutation.apply(op: "move") — the door Chunk::MOVE_MSG
  #                               names and the one V1::NodesController#move already uses.
  # Controllers call this and never reach into Sync:: or the port themselves; that seam is what
  # keeps the maker/file-layer split's §10 boundary honest.
  #
  # THE node_id NEVER CHANGES. That is the port's stated promise and the whole reason a move is
  # safe to perform on the user's behalf: every project attachment, BOM link and tag keeps
  # pointing at the same file.
  #
  # COLLISION IS DETECTED HERE, IN THE CATALOG, BEFORE EITHER DOOR IS OPENED, and it is a raise
  # rather than a clobber. Both port adapters already refuse to replace (Share#move raises
  # UnsupportedOperation, "…already exists"), but chunk mode has no such guard — Sync::Mutation
  # would happily create two live siblings with one name. Checking `nodes` is the only check that
  # is true on all three backends, and it is the catalog every backend actually reads.
  class MoveNode
    # A live node already holds the destination name. The caller decides what to do about it —
    # AttachmentsController turns it into the "rename or leave it" prompt.
    Collision = Class.new(StandardError)

    MAX_SUGGESTIONS = 9

    def self.call(user, node:, new_parent_node_id:, new_name: nil)
      new(user).call(node:, new_parent_node_id:, new_name:)
    end

    # The first free "<base> (n)<ext>" under `parent_node_id`, or nil if every variant up to
    # MAX_SUGGESTIONS is taken. Lives here because collision naming is this class's knowledge; the
    # conflict prompt reads it to label its button.
    def self.available_name(user, parent_node_id:, name:)
      ext  = File.extname(name)
      base = File.basename(name, ext)
      taken = user.nodes.present.where(parent_node_id:).pluck(:name).to_set
      (2..MAX_SUGGESTIONS).each do |i|
        candidate = "#{base} (#{i})#{ext}"
        return candidate unless taken.include?(candidate)
      end
      nil
    end

    def initialize(user)
      @user = user
      @port_writable = FileLayer.current.capabilities.port_writable?
    end

    def call(node:, new_parent_node_id:, new_name: nil)
      name = new_name.presence || node.name
      leaf!(name)
      collision!(node, new_parent_node_id, name)

      @port_writable ? port_move(node, new_parent_node_id, name) : chunk_move(node, new_parent_node_id, name)
      node
    end

    private

    # A name is a single path segment. The port adapters check this themselves (leaf!), but the
    # chunk door does not, and a name with a slash there would put a separator inside a node's
    # `name` column — a path that exists in no tree and that no mount can reproduce.
    def leaf!(name)
      return if name.present? && !name.include?("/") && !name.include?("\0") &&
                name != "." && name != ".."

      raise ArgumentError, "#{name.inspect} is not a valid file name"
    end

    # `where.not(node_id:)` is what makes a no-op move (already in the folder, same name) legal
    # rather than a collision with itself. Tombstones are excluded by `.present` — a deleted
    # sibling holds no name.
    def collision!(node, parent_node_id, name)
      taken = @user.nodes.present.where(parent_node_id:, name:)
                   .where.not(node_id: node.node_id).exists?
      raise Collision, name if taken
    end

    # share/s3: the port owns the store, so it renames the bytes and writes the row.
    def port_move(node, new_parent_node_id, name)
      FileLayer.current.move(@user, node_id: node.node_id,
                             new_parent_node_id:, new_name: name)
      node.reload
    end

    # chunk: the sync engine owns the tree (the port refuses move). Mirrors
    # V1::NodesController#move, broadcast included — a device following the changelog has to hear
    # about this or its tree diverges from the server's.
    def chunk_move(node, new_parent_node_id, name)
      seq = Sync::Mutation.apply(user: @user, node:, op: "move") do |n|
        n.parent_node_id = new_parent_node_id
        n.name = name
      end
      LibraryChannel.broadcast_change(@user, seq)
      node
    end
  end
end
```

- [ ] **Step 4: Run the test until green**

```bash
bin/rails test test/services/maker/move_node_test.rb
```

Expected: PASS, 10 runs, 0 failures, 0 errors.

- [ ] **Step 5: Verify the collision guard is load-bearing (mutation check)**

Temporarily delete the `collision!(node, new_parent_node_id, name)` line in `#call`, re-run, and confirm the two `Collision` tests go RED. Restore the line and confirm green again. A guard no test can kill is a guard that isn't tested.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/move_node.rb test/services/maker/move_node_test.rb
git commit -m "feat(files): Maker::MoveNode — the two-door library move

The third appearance of the port_writable branch (after LibraryFolder's
mkdir and FilesController#destroy), so it gets a name instead of a copy.
Collision is detected in the catalog, which is the only check true on all
three backends: chunk mode has no clobber guard of its own.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: The attach dropdown + already-attached chips

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/files_controller.rb` (`#show`)
- Modify: `app/controllers/projects/attachments_controller.rb` (`#create` dedupe)
- Modify: `app/views/files/show.html.erb:39-47`
- Modify: `app/assets/stylesheets/projects.css`
- Test: `test/integration/web/attach_from_files_test.rb`

- [ ] **Step 1: Write the failing tests**

Append these tests inside the existing `Web::AttachFromFilesTest` class in `test/integration/web/attach_from_files_test.rb` (keep the three tests already there, but **replace** the one named `"the file detail page offers an attach-to-project control listing the user's projects"` with the first test below — it asserts a `<select>` where the old one asserted buttons):

```ruby
    test "the file detail page offers a project dropdown, not a button per project" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      user.maker_projects.create!(name: "Lamp")
      user.maker_projects.create!(name: "Bench")

      get file_path("f-1")
      assert_response :success
      # One control, two options — the old UI rendered one <form><button> per project, so this
      # goes red if the button row comes back.
      assert_select ".attach-to-project select[name=project_id]", 1
      assert_select ".attach-to-project select option", 2
      assert_select ".attach-to-project select option", text: "Lamp"
      assert_select ".attach-to-project select option", text: "Bench"
    end

    test "the dropdown carries the project SLUG, which is what set_project resolves" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      user.maker_projects.create!(name: "Desk Lamp")

      get file_path("f-1")
      assert_select ".attach-to-project select option[value=desk-lamp]"
    end

    test "posting the non-nested attach route attaches, resolving the project from the body" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      project = user.maker_projects.create!(name: "Lamp")

      assert_difference "project.file_attachments.count", 1 do
        post attachments_path, params: { project_id: project.slug, node_id: "f-1" }
      end
    end

    test "attaching the same file to the same project twice creates ONE row" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      project = user.maker_projects.create!(name: "Lamp")

      post attachments_path, params: { project_id: project.slug, node_id: "f-1" }
      assert_difference "project.file_attachments.count", 0 do
        post attachments_path, params: { project_id: project.slug, node_id: "f-1" }
      end
    end

    test "projects the file is already in show as chips and drop out of the dropdown" do
      user = sign_in
      node = user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      lamp = user.maker_projects.create!(name: "Lamp")
      user.maker_projects.create!(name: "Bench")
      lamp.file_attachments.create!(user:, node_id: node.node_id, role: "model")

      get file_path("f-1")
      assert_select ".project-chip", text: /Lamp/
      # A file CAN be in several projects, so Bench is still offered — but Lamp is not, because
      # attaching it again is a no-op.
      assert_select ".attach-to-project select option", 1
      assert_select ".attach-to-project select option", text: "Bench"
    end

    test "a file attached to two projects shows two chips" do
      user = sign_in
      node = user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      %w[Lamp Bench].each do |n|
        user.maker_projects.create!(name: n).file_attachments
            .create!(user:, node_id: node.node_id, role: "model")
      end

      get file_path("f-1")
      assert_select ".project-chip", 2
    end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/integration/web/attach_from_files_test.rb
```

Expected: FAIL — `undefined local variable or method 'attachments_path'` and missing `select`/`.project-chip` elements.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, immediately AFTER the `resources :projects do … end` block (the one ending just before the `# Session-scoped "current project"` comment), add:

```ruby
  # NON-NESTED ATTACH. The file page attaches via a <select> of projects, and a <select> cannot
  # set its form's action — the nested route needs the project in the PATH. Rather than add JS to
  # rewrite `action` on change, the project rides as a body param here.
  # Projects::AttachmentsController#set_project reads params[:project_id], which resolves a body
  # param and a path segment identically, so this reaches the SAME action with no controller
  # change and no second create path. (`attachments_path` is free: the shallow `resources
  # :attachments` under :projects claims only project_attachments_path and the singular
  # attachment_path.)
  post "attachments", to: "projects/attachments#create", as: :attachments
```

- [ ] **Step 4: Make `#create` idempotent**

In `app/controllers/projects/attachments_controller.rb`, replace the `att = @project.file_attachments.create!(...)` line in `#create` with:

```ruby
      # find_or_create_by, not create!: maker_file_attachments has no uniqueness index (a unique
      # one would need a backfill dedupe, and this controller is the only writer), so a
      # double-submit or a second attach from the dropdown would otherwise make a duplicate row —
      # and the file page would then render the same project chip twice.
      att = @project.file_attachments.find_or_create_by!(user: current_user, node_id: node.node_id) do |a|
        a.role = Maker::FileAttachment.role_for(node.name)
      end
```

- [ ] **Step 5: Load the attach ivars in `FilesController#show`**

In `app/controllers/files_controller.rb`, replace this line in `#show`:

```ruby
    @projects = current_user.maker_projects.where.not(status: "archived").order(:name).to_a
```

with:

```ruby
    # THE ATTACH CONTROL'S TWO HALVES. `@attached_projects` is what the file is already in — a
    # file can be in several projects, and until now the page gave no sign it was in any. The
    # dropdown then offers the REST: re-attaching to a project it is already in is a no-op, so
    # listing it would be an option that does nothing.
    attachments = current_user.maker_file_attachments
                              .where(node_id: @node.node_id, attachable_type: "Maker::Project")
                              .includes(:attachable).to_a
    @attached_projects = attachments.filter_map { |a|
      [ a.attachable, a ] if a.attachable && a.attachable.status != "archived"
    }.sort_by { |project, _| project.name }
    scope = current_user.maker_projects.where.not(status: "archived")
    # Guarded: `where.not(id: [])` is a no-op clause in Rails, but writing it unconditionally
    # invites the reader to assume it filters. Say what happens.
    attached_ids = attachments.map(&:attachable_id)
    scope = scope.where.not(id: attached_ids) if attached_ids.any?
    @projects = scope.order(:name).to_a
```

- [ ] **Step 6: Replace the button row with the dropdown**

In `app/views/files/show.html.erb`, replace lines 39-47 (the `<% if @projects.present? %> … <% end %>` block) with:

```erb
<% if @projects.present? || @attached_projects.present? %>
  <div class="attach-to-project">
    <% if @attached_projects.present? %>
      <span class="muted">In projects:</span>
      <% @attached_projects.each do |project, attachment| %>
        <span class="project-chip">
          <%= link_to project.name, project_path(project) %>
          <%= button_to "×", attachment_path(attachment), method: :delete,
                form: { data: { turbo_confirm: "Detach #{@node.name} from #{project.name}?" } },
                class: "chip-x", "aria-label": "Detach from #{project.name}" %>
        </span>
      <% end %>
    <% end %>

    <% if @projects.present? %>
      <%#
        Posts to the NON-NESTED attachments_path so the project can travel as a body param — see
        the route comment. The option value is the SLUG, because set_project resolves
        find_by!(slug: params[:project_id]); an integer id here 404s. `return_to` brings the user
        back to this file page instead of the project (the nested picker keeps the old target).
      %>
      <%= form_with url: attachments_path, method: :post, class: "attach-form",
                    data: { turbo: false } do |f| %>
        <%= f.hidden_field :node_id, value: @node.node_id %>
        <%= f.hidden_field :return_to, value: "file" %>
        <%= f.label :project_id, "Attach to project:", class: "muted" %>
        <%= f.select :project_id, @projects.map { |p| [ p.name, p.slug ] } %>
        <%= f.submit "Attach", class: "btn small" %>
      <% end %>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 7: Style it**

Append to `app/assets/stylesheets/projects.css`:

```css
.attach-form { display: inline-flex; align-items: center; gap: 8px; }
.attach-form select { padding: 5px 8px; border: 1px solid var(--line); border-radius: 6px; }
.project-chip { display: inline-flex; align-items: center; gap: 4px; padding: 3px 4px 3px 10px;
  border: 1px solid var(--line); border-radius: 999px; font-size: 13px; }
.project-chip form { display: inline; }
.chip-x { background: none; border: 0; cursor: pointer; color: var(--muted);
  font-size: 15px; line-height: 1; padding: 0 4px; }
.chip-x:hover { color: var(--fg); }
```

- [ ] **Step 8: Run the test file until green**

```bash
bin/rails test test/integration/web/attach_from_files_test.rb
```

Expected: PASS, 8 runs, 0 failures, 0 errors.

- [ ] **Step 9: Confirm nothing else assumed the button row**

```bash
bin/rails test test/integration/web
```

Expected: 0 failures, 0 errors. If `project_attachments_test.rb` or `project_upload_attach_test.rb` fails, the `find_or_create_by!` change is the likely cause — read the failure before changing anything.

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb app/controllers/files_controller.rb \
  app/controllers/projects/attachments_controller.rb app/views/files/show.html.erb \
  app/assets/stylesheets/projects.css test/integration/web/attach_from_files_test.rb
git commit -m "feat(files): attach-to-project dropdown + already-attached chips

One <select> instead of a button per project, and the projects a file is
already in are finally visible (with a detach x). Attach is idempotent:
the table has no uniqueness index, so find_or_create_by is the guard.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: Auto-move the file into the project folder on attach

**Files:**
- Modify: `app/controllers/projects/attachments_controller.rb`
- Test: `test/integration/web/attach_auto_move_test.rb` (create)

**The rule:** on attach, move the file into the project's `Projects/<slug>/` folder **if and only
if** it had no *other* project attachment beforehand, and it is not already there. A file already
claimed by another project stays where it is.

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/attach_auto_move_test.rb`:

```ruby
require "test_helper"

module Web
  # Attaching a file to a project MOVES it into that project's library folder — unless it already
  # belongs to another project, in which case it stays where it is.
  #
  # PINNED TO CHUNK. The rule itself is backend-neutral, but the move it drives is the two-door
  # branch, and on share/s3 the port would need a real disk/bucket behind every fixture. The
  # doors themselves are covered per-backend in test/services/maker/move_node_test.rb; what this
  # file tests is the POLICY, which is one branch above them.
  class AttachAutoMoveTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @user = User.create!(email: "am-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @lamp = @user.maker_projects.create!(name: "Desk Lamp")
      @bench = @user.maker_projects.create!(name: "Bench")
      @node = @user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
    end

    def lamp_folder
      @user.nodes.present.find_by!(name: @lamp.slug, kind: "dir")
    end

    test "attaching an unattached file moves it into the project folder" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }

      @node.reload
      assert_equal lamp_folder.node_id, @node.parent_node_id
      assert_equal "f-1", @node.node_id, "the move must preserve node_id — the attachment points at it"
      assert_equal 1, @lamp.file_attachments.count
    end

    test "a file already attached to ANOTHER project is not moved" do
      @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      bench_folder = @bench.ensure_library_folder!(@user)
      @node.update!(parent_node_id: bench_folder.node_id)

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }

      assert_equal bench_folder.node_id, @node.reload.parent_node_id,
                   "a file claimed by another project stays put"
      assert_equal 1, @lamp.file_attachments.count, "…but the attach still happens"
    end

    test "a file already in the project folder is left alone (no redundant move)" do
      folder = @lamp.ensure_library_folder!(@user)
      @node.update!(parent_node_id: folder.node_id)

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }

      assert_equal folder.node_id, @node.reload.parent_node_id
      assert_empty @user.changelog_entries.where(op: "move"),
                   "nothing to move — the sync engine must not be told otherwise"
    end

    test "the project page's nested picker moves too — one rule, every attach path" do
      post project_attachments_path(@lamp), params: { node_id: "f-1" }
      assert_equal lamp_folder.node_id, @node.reload.parent_node_id
    end

    test "attaching from the file page returns to the file page, not the project" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }
      assert_redirected_to file_path("f-1")
    end

    test "attaching without return_to still lands on the project, as it always has" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
      assert_redirected_to project_path(@lamp)
    end

    test "a directory is never moved" do
      dir = @user.nodes.create!(node_id: "d-1", name: "cad", kind: "dir")
      post attachments_path, params: { project_id: @lamp.slug, node_id: "d-1" }
      assert_nil dir.reload.parent_node_id, "dirs are not relocated (s3 refuses them outright)"
    end

    test "an unreachable library leaves the attachment in place and says so" do
      Maker::MoveNode.stub(:call, ->(*, **) { raise FileLayer::FetchError, "nas is down" }) do
        post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
      end

      assert_equal 1, @lamp.file_attachments.count,
                   "an attach is bookkeeping — it must never fail because the NAS is unplugged"
      assert_match(/couldn't move/i, flash[:notice])
    end
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/integration/web/attach_auto_move_test.rb
```

Expected: FAIL — the first test reports `nil` for `parent_node_id` (nothing moves yet).

- [ ] **Step 3: Implement the policy**

In `app/controllers/projects/attachments_controller.rb`, replace the whole `#create` action with:

```ruby
    # POST /projects/:project_id/attachments  { node_id }
    # POST /attachments                       { project_id, node_id, return_to? }
    #
    # ATTACHING ALSO RELOCATES — the rule is the user's: a file joining its first project should
    # live in that project's folder, and a file already claimed by another project should not be
    # yanked out of it. Put here, at the ONE action every attach path reaches (the file page's
    # dropdown, the project page's picker, the importer's JSON attach), so the verb means the same
    # thing everywhere. Tool and importer UPLOADS already write straight into the project folder,
    # so they arrive in place and the "already there" check short-circuits.
    #
    # THE ATTACH IS THE DURABLE HALF AND THE MOVE IS BEST-EFFORT. A collision or an unmounted NAS
    # must never lose the attachment: it is a reference the user asked for, and it is exactly as
    # true with the bytes in the old folder. Same trade as #enqueue_preview and
    # CurrentProject#attach_addon_files_to_current_project.
    def create
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      unless node
        return respond_to do |format|
          format.html { redirect_to new_project_attachment_path(@project), alert: "That file isn't in your library." }
          format.json { render json: { error: "not_found" }, status: :not_found }
        end
      end

      # Read BEFORE the create below, or this attach is itself the "other" project.
      attached_elsewhere = current_user.maker_file_attachments
                                       .where(node_id: node.node_id, attachable_type: "Maker::Project")
                                       .where.not(attachable_id: @project.id).exists?

      # find_or_create_by, not create!: maker_file_attachments has no uniqueness index (a unique
      # one would need a backfill dedupe, and this controller is the only writer), so a
      # double-submit or a second attach from the dropdown would otherwise make a duplicate row —
      # and the file page would then render the same project chip twice.
      att = @project.file_attachments.find_or_create_by!(user: current_user, node_id: node.node_id) do |a|
        a.role = Maker::FileAttachment.role_for(node.name)
      end

      notice = "Attached #{node.name}."
      conflict = nil
      # Files only: a directory has no place in a project folder, and FileLayer::S3#move refuses
      # one outright (movable_file!) — so this would be a policy that silently works on one
      # backend and 422s on another.
      if node.file? && !attached_elsewhere
        case relocate_into_project(node)
        when :moved       then notice = "Attached #{node.name} and moved it into #{@project.name}."
        when :conflict    then conflict = att.id
        when :unavailable then notice = "Attached #{node.name} — couldn't move it into the project folder right now."
        end
      end

      respond_to do |format|
        format.html { redirect_to attach_redirect_path(node, conflict), notice: }
        format.json { render json: { node_id: att.node_id, role: att.role }, status: :created }
      end
    end
```

Then add these private methods below `set_project`:

```ruby
    # Move `node` into this project's library folder. Returns a SYMBOL rather than raising,
    # because every outcome here is a normal thing that happens to a user's library and the caller
    # renders a different sentence for each — an exception would make the happy path the only one
    # written down.
    def relocate_into_project(node, new_name: nil)
      folder = @project.ensure_library_folder!(current_user)
      return :already_there if new_name.nil? && node.parent_node_id == folder.node_id

      Maker::MoveNode.call(current_user, node:, new_parent_node_id: folder.node_id, new_name:)
      :moved
    rescue Maker::MoveNode::Collision
      :conflict
    rescue FileLayer::FetchError, FileLayer::UnsupportedOperation,
           ArgumentError, ActiveRecord::RecordInvalid => e
      # ArgumentError = a crafted new_name that isn't a leaf (MoveNode#leaf!). FetchError = the
      # share is unmounted or the bucket is unreachable. Neither is the user's fault and neither
      # is worth a 500 over a move we already called best-effort.
      Rails.logger.warn("attach relocate failed: #{e.class}: #{e.message}")
      :unavailable
    end

    # Where to land after an attach. `return_to` is an ALLOWLISTED FLAG, not a URL — a
    # caller-supplied redirect target is an open redirect, and there are exactly two places this
    # action is reached from. A collision rides back as ?move_conflict=<attachment id>, which is
    # what shared/_move_conflict.html.erb renders its prompt from.
    def attach_redirect_path(node, conflict_id)
      if params[:return_to] == "file"
        file_path(node.node_id, move_conflict: conflict_id)
      else
        project_path(@project, move_conflict: conflict_id)
      end
    end
```

- [ ] **Step 4: Run the test file until green**

```bash
bin/rails test test/integration/web/attach_auto_move_test.rb
```

Expected: PASS, 8 runs, 0 failures, 0 errors.

- [ ] **Step 5: Run every attach-touching test**

```bash
bin/rails test test/integration/web test/integration/tools
```

Expected: 0 failures, 0 errors. Files that exercise attach (`project_attachments_test.rb`,
`project_upload_attach_test.rb`, `models_import_test.rb`, the tools' auto-attach) now move files as
a side effect; if one asserts a file's `parent_node_id` it may legitimately need updating — read
the assertion and decide, don't blanket-update.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/projects/attachments_controller.rb \
  test/integration/web/attach_auto_move_test.rb
git commit -m "feat(projects): attaching a file moves it into the project folder

Only on a file's FIRST project — one already claimed elsewhere stays put.
The attach is durable and the move is best-effort: a collision or an
unmounted NAS must never lose a reference the user asked for.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: The collision prompt + `#relocate`

**Files:**
- Create: `app/controllers/concerns/move_conflicts.rb`
- Create: `app/views/shared/_move_conflict.html.erb`
- Modify: `config/routes.rb`, `app/controllers/projects/attachments_controller.rb`
- Modify: `app/controllers/files_controller.rb` (`#show`), `app/controllers/projects_controller.rb` (`#show`)
- Modify: `app/views/files/show.html.erb`, `app/views/projects/show.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/integration/web/attach_auto_move_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to the `Web::AttachAutoMoveTest` class in `test/integration/web/attach_auto_move_test.rb`:

```ruby
    test "a name collision attaches anyway and prompts instead of clobbering" do
      folder = @lamp.ensure_library_folder!(@user)
      @user.nodes.create!(node_id: "f-other", name: "bracket.stl", kind: "file",
                          parent_node_id: folder.node_id)

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }

      att = @lamp.file_attachments.sole
      assert_redirected_to file_path("f-1", move_conflict: att.id)
      assert_nil @node.reload.parent_node_id, "the file must not have moved…"
      assert_equal "bracket.stl", @user.nodes.find_by(node_id: "f-other").name,
                   "…and the file already there must be untouched"
    end

    test "the prompt offers the suggested name and a way out" do
      folder = @lamp.ensure_library_folder!(@user)
      @user.nodes.create!(node_id: "f-other", name: "bracket.stl", kind: "file",
                          parent_node_id: folder.node_id)
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }
      follow_redirect!

      assert_select "dialog.move-conflict"
      assert_select "dialog.move-conflict", text: /bracket \(2\)\.stl/
      assert_select "dialog.move-conflict a", text: /Leave it where it is/
    end

    test "the prompt also renders on the project page" do
      folder = @lamp.ensure_library_folder!(@user)
      @user.nodes.create!(node_id: "f-other", name: "bracket.stl", kind: "file",
                          parent_node_id: folder.node_id)
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
      follow_redirect!

      assert_select "dialog.move-conflict"
    end

    test "no prompt without the param, and a bogus id is silently ignored" do
      get file_path("f-1")
      assert_select "dialog.move-conflict", count: 0
      get file_path("f-1", move_conflict: 999_999)
      assert_select "dialog.move-conflict", count: 0
    end

    test "another user's attachment id never renders a prompt" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      other_node = other.nodes.create!(node_id: "of-1", name: "x.stl", kind: "file")
      foreign = other.maker_projects.create!(name: "Theirs")
                     .file_attachments.create!(user: other, node_id: other_node.node_id, role: "model")

      get file_path("f-1", move_conflict: foreign.id)
      assert_select "dialog.move-conflict", count: 0
    end

    test "relocate moves the file under the suggested name" do
      folder = @lamp.ensure_library_folder!(@user)
      @user.nodes.create!(node_id: "f-other", name: "bracket.stl", kind: "file",
                          parent_node_id: folder.node_id)

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "bracket (2).stl" }

      @node.reload
      assert_equal folder.node_id, @node.parent_node_id
      assert_equal "bracket (2).stl", @node.name
      assert_equal "f-1", @node.node_id
    end

    test "relocate onto a name that is ALSO taken says so instead of clobbering" do
      folder = @lamp.ensure_library_folder!(@user)
      @user.nodes.create!(node_id: "f-other", name: "bracket (2).stl", kind: "file",
                          parent_node_id: folder.node_id)

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "bracket (2).stl" }

      assert_nil @node.reload.parent_node_id
      assert_match(/taken/i, flash[:alert])
    end

    test "relocate refuses a name that escapes the folder" do
      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "../escape.stl" }

      assert_nil @node.reload.parent_node_id
      assert_equal "bracket.stl", @node.reload.name
    end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/integration/web/attach_auto_move_test.rb
```

Expected: FAIL — `undefined local variable or method 'relocate_project_attachments_path'`.

- [ ] **Step 3: Add the relocate route**

In `config/routes.rb`, change the attachments line inside `resources :projects do` from:

```ruby
    resources :attachments, only: %i[new create destroy], module: :projects, shallow: true
```

to:

```ruby
    resources :attachments, only: %i[new create destroy], module: :projects, shallow: true do
      # Finish an attach whose auto-move hit a name collision: move the file in under a new name.
      # DELIBERATELY SCOPED TO THE PROJECT rather than a general POST /files/:id/move — the
      # conflict flow needs a move endpoint either way, and this one can only ever move a file
      # into the named project's own folder. A general move is a larger web surface than any
      # feature here wants. `on: :collection` keeps it nested despite `shallow: true`.
      post :relocate, on: :collection
    end
```

- [ ] **Step 4: Add the `#relocate` action**

In `app/controllers/projects/attachments_controller.rb`, change the `before_action` line to:

```ruby
    before_action :set_project, only: %i[new create relocate]
```

and add this action after `#create`:

```ruby
    # POST /projects/:project_id/attachments/relocate  { node_id, new_name }
    # The "Move it in as …" button on the collision prompt. `new_name` is server-suggested
    # (Maker::MoveNode.available_name), but it arrives as a param, so MoveNode validates it is a
    # leaf and relocate_into_project maps the refusal to :unavailable — a crafted name gets a
    # flash, never a traversal and never a 500.
    def relocate
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      return redirect_to(project_path(@project), alert: "That file isn't in your library.") unless node

      case relocate_into_project(node, new_name: params[:new_name].presence)
      when :moved
        redirect_to project_path(@project), notice: "Moved #{node.name} into #{@project.name}."
      when :conflict
        redirect_to project_path(@project), alert: "That name is taken too — left the file where it is."
      else
        redirect_to project_path(@project), alert: "Couldn't move #{node.name} right now."
      end
    end
```

- [ ] **Step 5: Add the concern that resolves the prompt**

Create `app/controllers/concerns/move_conflicts.rb`:

```ruby
# Resolve `?move_conflict=<attachment id>` into everything shared/_move_conflict.html.erb needs.
#
# A CONTROLLER CONCERN, NOT VIEW LOGIC, for the reason FilesController#index already gives about
# @current_project_folder_node_id: a view must not run queries — or worse, create a project folder
# — as a side effect of being rendered. The owning action opts in and hands the view one ivar.
#
# Everything is scoped to current_user, so a guessed or foreign attachment id resolves to nil and
# the prompt simply does not render. nil is the answer for every "can't build a prompt" case
# (missing param, stale id, tombstoned file, a project whose folder was never created) — this is
# a transient UI affordance, and a 404 for a dismissed prompt would be worse than silence.
module MoveConflicts
  extend ActiveSupport::Concern

  ConflictPrompt = Struct.new(:attachment, :project, :node, :suggested_name, keyword_init: true)

  private

  def move_conflict_prompt
    id = params[:move_conflict].presence
    return nil unless id && current_user

    attachment = current_user.maker_file_attachments
                             .find_by(id: id, attachable_type: "Maker::Project")
    return nil unless attachment

    project = attachment.attachable
    node = current_user.nodes.present.find_by(node_id: attachment.node_id)
    return nil unless project && node && project.folder_node_id.present?

    ConflictPrompt.new(
      attachment:, project:, node:,
      suggested_name: Maker::MoveNode.available_name(
        current_user, parent_node_id: project.folder_node_id, name: node.name
      )
    )
  end
end
```

- [ ] **Step 6: Create the prompt partial**

Create `app/views/shared/_move_conflict.html.erb`:

```erb
<%#
  The collision prompt: the attach already happened, the move did not. Rendered on BOTH the file
  page and the project page, because an attach can come from either.

  `open` on a plain <dialog> renders it in the document flow (not the top layer) — no JS, and it
  degrades to an ordinary panel everywhere. "Leave it where it is" links to request.path, which is
  this same page WITHOUT the query string: the dismissal is just the URL without the param, and
  building it that way avoids url_for(params:) — which this codebase has been bitten by before.
%>
<% if @move_conflict %>
  <dialog class="move-conflict" open>
    <p>
      <strong><%= @move_conflict.node.name %></strong> is attached to
      <%= link_to @move_conflict.project.name, project_path(@move_conflict.project) %>,
      but a file with that name is already in the project's folder — so it was left where it is.
    </p>
    <div class="dialog-actions">
      <% if @move_conflict.suggested_name %>
        <%= button_to "Move it in as “#{@move_conflict.suggested_name}”",
                      relocate_project_attachments_path(@move_conflict.project),
                      params: { node_id: @move_conflict.node.node_id,
                                new_name: @move_conflict.suggested_name },
                      class: "btn" %>
      <% end %>
      <%= link_to "Leave it where it is", request.path, class: "btn ghost" %>
    </div>
  </dialog>
<% end %>
```

- [ ] **Step 7: Wire both pages**

In `app/controllers/files_controller.rb`, add below the `include LibraryCapabilities` line:

```ruby
  # ?move_conflict=<id> — the prompt an attach leaves behind when the auto-move hit a name
  # collision. Rendered here and on the project page; an attach can come from either.
  include MoveConflicts
```

and at the END of `#show` (after the `@notes = …` line) add:

```ruby
    @move_conflict = move_conflict_prompt
```

In `app/controllers/projects_controller.rb`, add `include MoveConflicts` below the existing
`before_action`/`include` lines at the top of the class, and add `@move_conflict =
move_conflict_prompt` at the end of `#show`.

In `app/views/files/show.html.erb`, add immediately AFTER the `<div class="page-head">…</div>`
block (before `<dl class="meta">`):

```erb
<%= render "shared/move_conflict" %>
```

In `app/views/projects/show.html.erb`, add the same line immediately after the page's
`<div class="page-head">…</div>` block.

- [ ] **Step 8: Style the dialog**

Append to `app/assets/stylesheets/application.css`:

```css
dialog.move-conflict { display: block; position: static; width: 100%; max-width: none;
  margin: 0 0 16px; padding: 14px 16px; border: 1px solid var(--line); border-left: 4px solid var(--accent);
  border-radius: 8px; background: var(--soft); color: var(--fg); }
dialog.move-conflict p { margin: 0 0 10px; }
dialog.move-conflict .dialog-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
dialog.move-conflict form { display: inline; }
```

- [ ] **Step 9: Run until green**

```bash
bin/rails test test/integration/web/attach_auto_move_test.rb
```

Expected: PASS, 16 runs, 0 failures, 0 errors.

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb app/controllers/concerns/move_conflicts.rb \
  app/controllers/projects/attachments_controller.rb app/controllers/files_controller.rb \
  app/controllers/projects_controller.rb app/views/shared/_move_conflict.html.erb \
  app/views/files/show.html.erb app/views/projects/show.html.erb \
  app/assets/stylesheets/application.css test/integration/web/attach_auto_move_test.rb
git commit -m "feat(projects): prompt to rename when an attach can't move the file in

A name collision keeps the attachment and asks, instead of clobbering or
silently doing nothing. The relocate endpoint is scoped to the project's
own folder — the conflict flow needs a move, not a general one.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: Sortable columns

**Files:**
- Create: `app/helpers/files_helper.rb`
- Modify: `app/controllers/files_controller.rb`
- Modify: `app/views/files/_list.html.erb:6-13`, `app/views/files/index.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/integration/web/files_sort_test.rb` (create)

**Keys:** `name` (A→Z), `type` (extension), `modified` (mtime). Default `name asc`. Remembered in a
`files_sort` cookie, whitelisted exactly like `resolve_view` already whitelists `files_view`.

**Sorting happens in Ruby, not SQL** — "type" means extension, and there is no expression for it
portable across SQLite (self-host) and Postgres (managed). A denormalized `ext` column would have
to be written by `Sync::Commit` and `Sync::Mutation`, which is the §10 tripwire. See spec §5.2.
Do not "optimize" this into an `ORDER BY`.

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/files_sort_test.rb`:

```ruby
require "test_helper"

module Web
  # Column sorting in the file browser. DELIBERATELY NOT PINNED TO A BACKEND: name and kind come
  # from `nodes`, and mtime comes from stat_all, which answers from `nodes` on all three adapters
  # — so bare seeded rows prove this is backend-neutral. Must stay green on `bin/rails test`,
  # `LIBRARY_BACKEND=share` and `LIBRARY_BACKEND=s3`.
  class FilesSortTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "sort-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }

      # Names, extensions and mtimes deliberately disagree, so each sort key produces a DIFFERENT
      # order and no assertion can pass by accident.
      #   name A→Z:   alpha.stl, beta.3mf, gamma.pdf
      #   type A→Z:   beta.3mf (3mf), gamma.pdf (pdf), alpha.stl (stl)
      #   modified ↑: gamma.pdf, alpha.stl, beta.3mf
      file("alpha.stl", 2_000)
      file("beta.3mf",  3_000)
      file("gamma.pdf", 1_000)
      @user.nodes.create!(node_id: "d-1", name: "zeta-folder", kind: "dir")
    end

    def file(name, mtime_seconds)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          mtime: mtime_seconds * 1_000_000_000, size: 10)
    end

    # The rendered order of the file names, in document order.
    #
    # PREFER .file-name, FALL BACK TO THE LINK. A file the app can thumbnail renders its name in a
    # `<span class="file-name">` inside a link that ALSO contains the thumbnail cell — so reading
    # the `<a>`'s text would return "STL alpha.stl" for those rows and "gamma.pdf" for the rest,
    # and every ordering assertion below would be comparing against markup instead of names.
    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip.delete_prefix("📁 ")
      end
    end

    test "defaults to name ascending" do
      get files_path
      assert_equal %w[alpha.stl beta.3mf gamma.pdf zeta-folder], listed_names
    end

    test "name descending reverses the files but keeps folders grouped last" do
      get files_path(sort: "name", dir: "desc")
      assert_equal %w[gamma.pdf beta.3mf alpha.stl zeta-folder], listed_names
    end

    test "sorts by type (extension), not by name" do
      get files_path(sort: "type", dir: "asc")
      assert_equal %w[beta.3mf gamma.pdf alpha.stl zeta-folder], listed_names
    end

    test "sorts by modified, and mtime is read as NANOSECONDS" do
      get files_path(sort: "modified", dir: "asc")
      assert_equal %w[gamma.pdf alpha.stl beta.3mf zeta-folder], listed_names

      get files_path(sort: "modified", dir: "desc")
      assert_equal %w[beta.3mf alpha.stl gamma.pdf zeta-folder], listed_names
    end

    test "the choice persists in a cookie across a request with no params" do
      get files_path(sort: "type", dir: "asc")
      get files_path
      assert_equal %w[beta.3mf gamma.pdf alpha.stl zeta-folder], listed_names
    end

    test "junk sort and dir params fall back to the default" do
      get files_path(sort: "'; DROP TABLE nodes; --", dir: "sideways")
      assert_response :success
      assert_equal %w[alpha.stl beta.3mf gamma.pdf zeta-folder], listed_names
    end

    test "a tampered cookie falls back to the default" do
      cookies[:files_sort] = "size:ascending"
      get files_path
      assert_equal %w[alpha.stl beta.3mf gamma.pdf zeta-folder], listed_names
    end

    test "the headers are links that toggle direction and carry aria-sort" do
      get files_path(sort: "name", dir: "asc")
      assert_select "th[aria-sort=ascending]", text: /Name/
      # Clicking the ACTIVE column flips it; an inactive one starts ascending.
      assert_select "th a[href=?]", files_path(sort: "name", dir: "desc")
      assert_select "th a[href=?]", files_path(sort: "type", dir: "asc")
    end

    test "sorting inside a folder keeps the folder" do
      dir = @user.nodes.create!(node_id: "d-2", name: "cad", kind: "dir")
      @user.nodes.create!(node_id: "n-in", name: "inner.stl", kind: "file",
                          parent_node_id: dir.node_id, mtime: 1)

      get files_path(folder: "d-2", sort: "type", dir: "asc")
      assert_equal %w[inner.stl], listed_names
      assert_select "th a[href=?]", files_path(folder: "d-2", sort: "name", dir: "asc")
    end

    test "grid view offers the same sort as a select" do
      get files_path(view: "grid", sort: "type", dir: "desc")
      assert_select "form.sort-form select[name=sort] option[value=type][selected=selected]"
      assert_select "form.sort-form select[name=dir] option[value=desc][selected=selected]"
    end
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/integration/web/files_sort_test.rb
```

Expected: FAIL — the default-order test may pass by luck, but `sorts by type`, the aria-sort test
and the grid test all fail (no sorting exists).

- [ ] **Step 3: Add sort resolution to the controller**

In `app/controllers/files_controller.rb`, directly below the existing `VIEWS`/`DEFAULT_VIEW`
constants and `resolve_view` method (in the `private` section), add:

```ruby
  # Sort key + direction. Same whitelist idiom as resolve_view, and for the same reason: an
  # unknown `?sort=` or a tampered cookie must fall back to the default rather than reach the
  # sorter as an arbitrary string. Stored as one "key:dir" cookie value.
  SORTS = %w[name type modified].freeze
  DEFAULT_SORT = "name".freeze
  DIRS = %w[asc desc].freeze
  DEFAULT_DIR = "asc".freeze

  def resolve_sort
    requested = params[:sort].presence
    if SORTS.include?(requested)
      dir = DIRS.include?(params[:dir]) ? params[:dir] : DEFAULT_DIR
      cookies[:files_sort] = { value: "#{requested}:#{dir}", expires: 1.year }
      return [ requested, dir ]
    end
    key, dir = cookies[:files_sort].to_s.split(":")
    return [ key, dir ] if SORTS.include?(key) && DIRS.include?(dir)

    [ DEFAULT_SORT, DEFAULT_DIR ]
  end

  # IN RUBY, NOT IN SQL, AND THAT IS A DECISION (spec §5.2). "type" means the file's EXTENSION,
  # and there is no expression for it portable across SQLite (self-host) and Postgres (managed) —
  # substr/instr vs substring/position. The alternative, a denormalized `ext` column on `nodes`,
  # would have to be populated by Sync::Commit and Sync::Mutation: writing to the sync layer to
  # serve a web view, which is the maker/file-layer split's §10 tripwire. So all three keys sort
  # the same way, uniformly, and none is more exact than another. The cost is the shape this
  # action already has (it loads the folder with .to_a and select!s in memory).
  #
  # Ruby's sort_by is NOT STABLE, so both passes carry the index as a tiebreak — without it,
  # equal keys (two .stl files, two nodes with the same mtime) shuffle between page loads.
  #
  # Directories stay grouped AFTER files exactly as today's `kind: :desc` ordering leaves them,
  # and `dir` reverses only WITHIN the sort, so a descending sort never scatters folders through
  # the file list.
  def sort_nodes(nodes, info, key, dir)
    ordered = nodes.each_with_index.sort_by { |node, i| [ sort_key(node, info, key), i ] }.map(&:first)
    ordered.reverse! if dir == "desc"
    ordered.each_with_index.sort_by { |node, i| [ node.kind == "dir" ? 1 : 0, i ] }.map(&:first)
  end

  def sort_key(node, info, key)
    case key
    when "type"     then File.extname(node.name).downcase.delete(".")
    when "modified" then info[node.node_id]&.mtime || 0
    else                 node.name.downcase
    end
  end

  # Query params every in-page link must carry so sorting never drops the user's folder or filter.
  # `view` is deliberately absent: it is cookie-persisted, so carrying it would pin a choice the
  # user can no longer change from the toggle.
  helper_method :files_query_base
  def files_query_base
    { folder: @folder&.node_id }.compact
  end
```

- [ ] **Step 4: Apply the sort in `#index`**

In `app/controllers/files_controller.rb#index`, change the first line from `@view = resolve_view`
to:

```ruby
    @view = resolve_view
    @sort, @dir = resolve_sort
```

and immediately AFTER the existing `@nodes.select! { |node| @info_by_node.key?(node.node_id) }`
line, add:

```ruby
    # After select!, so a node that vanished between the two queries is gone before it can be
    # given a sort position; before the note/thumbnail loads, which only need the final list.
    @nodes = sort_nodes(@nodes, @info_by_node, @sort, @dir)
```

- [ ] **Step 5: Add the header helper**

Create `app/helpers/files_helper.rb`:

```ruby
module FilesHelper
  # A sortable column header. Clicking the ACTIVE column flips its direction; clicking any other
  # starts it ascending. `extra` carries the folder/filter params so sorting never drops them.
  #
  # aria-sort is what makes this usable with a screen reader — a "▲" in the label is invisible to
  # one, and a column that announces no sort state is a column you cannot navigate.
  def sort_header(label, key, current_sort, current_dir, extra = {}, html: {})
    active = current_sort == key
    next_dir = (active && current_dir == "asc") ? "desc" : "asc"
    arrow = active ? (current_dir == "asc" ? " ▲" : " ▼") : ""
    aria  = active ? (current_dir == "asc" ? "ascending" : "descending") : "none"
    classes = [ html[:class], ("sorted" if active) ].compact.join(" ")
    tag.th("aria-sort": aria, class: classes.presence) do
      link_to("#{label}#{arrow}", files_path(extra.merge(sort: key, dir: next_dir)))
    end
  end
end
```

- [ ] **Step 6: Use it in the list header**

In `app/views/files/_list.html.erb`, replace the `<thead>…</thead>` block (lines 7-13) with:

```erb
  <thead>
    <tr>
      <%= sort_header "Name", "name", @sort, @dir, files_query_base %>
      <%= sort_header "Type", "type", @sort, @dir, files_query_base %>
      <%# Size is NOT sortable, and that is deliberate: it is the one column whose value does not
          come from `nodes` on every backend (Chunk#stat_all reads it from the versions row), so a
          size sort would be the only inexact one — worse than none in a column of exact-looking
          numbers. See the spec, §5.3. %>
      <th class="num">Size</th>
      <% if capabilities.versioned? %><th>Version</th><% end %>
      <%= sort_header "Modified", "modified", @sort, @dir, files_query_base %>
      <th></th>
    </tr>
  </thead>
```

- [ ] **Step 7: Add the grid sort control**

In `app/views/files/index.html.erb`, replace the final render block at the bottom:

```erb
<% if @nodes.empty? %>
  <p class="empty muted">No files yet. Upload one to get started.</p>
<% elsif @view == "grid" %>
  <%= render "grid" %>
<% else %>
  <%= render "list" %>
<% end %>
```

with:

```erb
<% if @nodes.empty? %>
  <p class="empty muted">No files yet. Upload one to get started.</p>
<% elsif @view == "grid" %>
  <%#
    The grid has no column headers to click, so it gets the same sort as a pair of selects. GET,
    so the result is a plain shareable URL exactly like the header links produce. `onchange`
    submits without JS of our own (an inline handler on a native form, not a controller).
  %>
  <form method="get" action="<%= files_path %>" class="sort-form">
    <% files_query_base.each do |k, v| %>
      <input type="hidden" name="<%= k %>" value="<%= v %>">
    <% end %>
    <label class="muted" for="sort-key">Sort</label>
    <select name="sort" id="sort-key" onchange="this.form.requestSubmit()">
      <% { "name" => "Name", "type" => "Type", "modified" => "Modified" }.each do |value, label| %>
        <option value="<%= value %>" <%= "selected" if @sort == value %>><%= label %></option>
      <% end %>
    </select>
    <select name="dir" aria-label="Sort direction" onchange="this.form.requestSubmit()">
      <option value="asc"  <%= "selected" if @dir == "asc" %>>Ascending</option>
      <option value="desc" <%= "selected" if @dir == "desc" %>>Descending</option>
    </select>
  </form>
  <%= render "grid" %>
<% else %>
  <%= render "list" %>
<% end %>
```

- [ ] **Step 8: Style it**

Append to `app/assets/stylesheets/application.css`:

```css
table.files th.sorted a { color: var(--fg); font-weight: 700; }
table.files th a { color: inherit; }
table.files th a:hover { text-decoration: underline; }
.sort-form { display: flex; align-items: center; gap: 8px; margin: 0 0 12px; }
.sort-form select { padding: 5px 8px; border: 1px solid var(--line); border-radius: 6px; }
```

- [ ] **Step 9: Run until green**

```bash
bin/rails test test/integration/web/files_sort_test.rb
```

Expected: PASS, 10 runs, 0 failures, 0 errors.

- [ ] **Step 10: Verify the stability tiebreak is load-bearing**

Temporarily drop the `, i` from the FIRST `sort_by` in `sort_nodes` and re-run the whole web suite
a few times:

```bash
for i in 1 2 3; do bin/rails test test/integration/web/files_sort_test.rb || break; done
```

Ruby's `sort_by` is unstable, so this may or may not go red — that is the point. Restore the `, i`
either way and leave the comment explaining it.

- [ ] **Step 11: Commit**

```bash
git add app/controllers/files_controller.rb app/helpers/files_helper.rb \
  app/views/files/_list.html.erb app/views/files/index.html.erb \
  app/assets/stylesheets/application.css test/integration/web/files_sort_test.rb
git commit -m "feat(files): sortable Name / Type / Modified columns

Sorted in Ruby, not SQL: 'type' means extension, which has no expression
portable across SQLite and Postgres, and the denormalized column that
would fix that has to be written by Sync::Commit — the §10 tripwire.
No size sort; it is the one value not read from nodes on every backend.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: The flat by-extension filter

**Files:**
- Modify: `app/controllers/files_controller.rb`
- Modify: `app/helpers/files_helper.rb`
- Create: `app/views/files/_ext_filter.html.erb`
- Modify: `app/views/files/index.html.erb`, `app/views/files/_list.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/integration/web/files_type_filter_test.rb` (create)

`?ext=stl,3mf` switches `/files` to a **flat, whole-library list of just those file types**,
ignoring `?folder=` entirely. Files only — a directory has no extension.

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/files_type_filter_test.rb`:

```ruby
require "test_helper"

module Web
  # The flat by-extension view: "show me every .stl in my library, wherever it lives."
  # BACKEND-NEUTRAL by construction — it filters `nodes.name`, which all three adapters populate.
  class FilesTypeFilterTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "ext-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }

      #   /root.stl
      #   /notes.pdf
      #   /cad/                     (dir-cad)
      #   /cad/deep.stl             <- the one a folder view would hide
      #   /cad/part.3mf
      #   /cad/sub/                 (dir-sub)
      #   /cad/sub/tiny.stl
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      @user.nodes.create!(node_id: "dir-sub", name: "sub", kind: "dir", parent_node_id: "dir-cad")
      file("root.stl",  nil)
      file("notes.pdf", nil)
      file("deep.stl",  "dir-cad")
      file("part.3mf",  "dir-cad")
      file("tiny.stl",  "dir-sub")
    end

    def file(name, parent)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1_000_000_000, size: 5)
    end

    # Same reader as files_sort_test.rb — a thumbnailable file's link contains the thumbnail cell
    # as well as the name, so read the .file-name span when there is one.
    def listed_names
      css_select("table.files tbody tr td:first-child").map do |cell|
        (cell.at_css(".file-name") || cell.at_css("a")).text.strip.delete_prefix("📁 ")
      end
    end

    test "one extension lists every match in the library, at any depth" do
      get files_path(ext: "stl")
      assert_equal %w[deep.stl root.stl tiny.stl], listed_names.sort
    end

    test "several extensions compose" do
      get files_path(ext: "stl,3mf")
      assert_equal %w[deep.stl part.3mf root.stl tiny.stl], listed_names.sort
    end

    test "the filter ignores ?folder= — flat means the whole library" do
      get files_path(folder: "dir-sub", ext: "stl")
      assert_equal %w[deep.stl root.stl tiny.stl], listed_names.sort
    end

    test "directories never appear in a type view" do
      get files_path(ext: "stl")
      assert_select "a.dir", count: 0
      assert_not_includes listed_names, "cad"
    end

    test "matching is case-insensitive on the extension" do
      file("SHOUTY.STL", nil)
      get files_path(ext: "stl")
      assert_includes listed_names, "SHOUTY.STL"
    end

    test "an extension is matched at the END of the name, not anywhere in it" do
      file("stl-notes.txt", nil)
      get files_path(ext: "stl")
      assert_not_includes listed_names, "stl-notes.txt"
    end

    test "junk extensions are dropped, not queried" do
      get files_path(ext: "../etc,%,thisiswaytoolong,st l")
      assert_response :success
      # Nothing valid survived the whitelist, so this is an ordinary folder view.
      assert_includes listed_names, "cad"
    end

    test "a LIKE metacharacter cannot widen the match" do
      # '%' is dropped by the whitelist entirely; assert the behaviour, not the mechanism.
      get files_path(ext: "s%l")
      assert_response :success
      assert_includes listed_names, "cad", "an escaped-away filter must fall back to folder view"
    end

    test "no matches renders an empty state, not an error" do
      get files_path(ext: "dxf")
      assert_response :success
      assert_select ".empty", text: /No files match/i
    end

    test "the flat list shows which folder each file is in" do
      get files_path(ext: "stl")
      assert_select "th", text: "Folder"
      assert_select "table.files tbody tr", text: /cad\/sub/
    end

    test "chips mark the active extensions and toggle them off" do
      get files_path(ext: "stl")
      assert_select ".ext-filter a.chip.active", text: /stl/
      # Clicking the active chip removes it.
      assert_select ".ext-filter a.chip.active[href=?]", files_path(sort: "name", dir: "asc")
    end

    test "the free-text field adds an extension the chip list doesn't know" do
      file("model.f3d", nil)
      get files_path(add_ext: "f3d")
      assert_equal %w[model.f3d], listed_names
    end

    test "sorting still applies inside a filtered view" do
      get files_path(ext: "stl", sort: "name", dir: "desc")
      assert_equal %w[tiny.stl root.stl deep.stl], listed_names
    end

    test "the result set is bounded and says so when it truncates" do
      original = FilesController::FLAT_LIMIT
      FilesController.send(:remove_const, :FLAT_LIMIT)
      FilesController.const_set(:FLAT_LIMIT, 2)
      begin
        get files_path(ext: "stl")
        assert_equal 2, listed_names.size
        assert_select ".truncated", text: /first 2 of 3/i
      ensure
        FilesController.send(:remove_const, :FLAT_LIMIT)
        FilesController.const_set(:FLAT_LIMIT, original)
      end
    end
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/integration/web/files_type_filter_test.rb
```

Expected: FAIL — the filter does nothing yet, so the first test lists nothing (root-only view).

- [ ] **Step 3: Add ext resolution + flat mode to the controller**

In `app/controllers/files_controller.rb`, add to the `private` section (below `resolve_sort`):

```ruby
  # A file extension is 1-8 lowercase alphanumerics. ANYTHING ELSE IS DROPPED, not escaped and not
  # rejected with an error: this arrives in a URL a user can hand-edit or a crawler can mangle, and
  # falling back to the ordinary folder view is the honest answer to "that isn't an extension".
  # The whitelist is also what bounds the LIKE below — sanitize_sql_like alone would still let a
  # 4KB `ext` build a query with hundreds of OR clauses.
  EXT_RE = /\A[a-z0-9]{1,8}\z/
  MAX_EXTS = 8
  # The one bound this page has ever had. The folder view is still unbounded (a folder is
  # self-limiting; a whole-library type view is not), and the truncation is ANNOUNCED — a silent
  # cut reads as "that's all your STLs", which is the same class of lie as a paginated listing
  # mistaken for a snapshot. Pagination is the follow-up if a real library hits this.
  FLAT_LIMIT = 2000

  # `add_ext` is the free-text field beside the chips; it simply joins the list, so there is one
  # filter param and one code path rather than two ways to say the same thing.
  def resolve_exts
    [ params[:ext], params[:add_ext] ].compact_blank.join(",")
      .downcase.split(",").map(&:strip).select { |e| e.match?(EXT_RE) }.uniq.first(MAX_EXTS)
  end

  # Every file in the library whose name ends in one of `exts`. One OR-ed LIKE per extension, all
  # bound — the interpolation is the CLAUSE (a fixed string repeated), never a value.
  def flat_ext_scope(exts)
    clause = Array.new(exts.size, "LOWER(name) LIKE ?").join(" OR ")
    args = exts.map { |e| "%.#{ActiveRecord::Base.sanitize_sql_like(e)}" }
    current_user.nodes.present.where(kind: "file").where(clause, *args)
  end

  # node_id -> "cad/sub" for the flat view's Folder column, because a flat list of 200 STLs with no
  # location is unnavigable. ONE query for the user's dirs (a library has few, even with a great
  # many files), assembled in Ruby — never a parent walk per row. The `visited` marker is the same
  # cycle guard folder_crumbs uses: a corrupt parent chain must not recurse forever.
  def folder_paths_for(nodes)
    dirs = current_user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)
    by_id = dirs.to_h { |id, parent, name| [ id, [ parent, name ] ] }
    cache = {}
    resolve = lambda do |id|
      return "" if id.nil? || !by_id.key?(id)
      return cache[id] if cache.key?(id)

      cache[id] = "…" # cycle marker: re-entering this id returns it instead of recursing
      parent, name = by_id[id]
      cache[id] = [ resolve.call(parent), name ].reject(&:blank?).join("/")
    end
    nodes.to_h { |n| [ n.node_id, resolve.call(n.parent_node_id) ] }
  end
```

- [ ] **Step 4: Branch `#index` on flat mode**

In `app/controllers/files_controller.rb#index`, replace these three lines:

```ruby
    @folder = current_folder
    @crumbs = folder_crumbs(@folder)
    @nodes = current_user.nodes.present.where(parent_node_id: @folder&.node_id)
                         .order(kind: :desc, name: :asc).to_a
```

with:

```ruby
    # FLAT MODE. An extension filter is a question about the LIBRARY, not about a folder, so
    # ?folder= is ignored outright rather than intersected — "show me every .stl" that quietly
    # meant "in this folder" would be the wrong answer to the only question the chips can ask.
    @exts = resolve_exts
    @flat = @exts.any?
    if @flat
      @folder = nil
      @crumbs = []
      scope = flat_ext_scope(@exts)
      @match_count = scope.count
      @nodes = scope.order(:name).limit(FLAT_LIMIT).to_a
      @truncated = @match_count > FLAT_LIMIT
    else
      @folder = current_folder
      @crumbs = folder_crumbs(@folder)
      @nodes = current_user.nodes.present.where(parent_node_id: @folder&.node_id)
                           .order(kind: :desc, name: :asc).to_a
      @truncated = false
    end
```

Then, immediately after the `@nodes = sort_nodes(...)` line added in Task 5, add:

```ruby
    @folder_paths = @flat ? folder_paths_for(@nodes) : {}
```

- [ ] **Step 5: Carry the filter on every in-page link**

In `app/controllers/files_controller.rb`, replace the `files_query_base` method body (added in
Task 5) with:

```ruby
  def files_query_base
    { folder: @folder&.node_id, ext: @exts.presence&.join(",") }.compact
  end
```

- [ ] **Step 6: Add the chip families to the helper**

Append inside `module FilesHelper` in `app/helpers/files_helper.rb`:

```ruby
  # The chip row's vocabulary: the extensions this app already knows something about (the union of
  # what Maker::Previews::Registry can render and what FileAttachment::ROLE_BY_EXT assigns a role
  # to), grouped so the row reads as a maker's shelf rather than an alphabet.
  #
  # A CURATED LIST, NOT REAL FACET COUNTS, and the reason is cost: counting "you have 214 .stl
  # files" means plucking every filename in the library on EVERY Files page load, including plain
  # folder browsing that never looks at the chips. A chip that matches nothing is a harmless dead
  # end; a query the folder view pays for and never reads is not. The free-text field beside the
  # row is what covers a format this list has never heard of.
  EXT_FAMILIES = {
    "3D models"  => %w[stl 3mf obj step stp],
    "2D / laser" => %w[svg dxf lbrn2],
    "Documents"  => %w[pdf txt md csv],
    "Images"     => %w[png jpg jpeg webp],
    "Machine"    => %w[gcode zip]
  }.freeze

  # The URL for toggling `ext` into or out of the active set, preserving the sort.
  def ext_toggle_path(ext, active_exts, sort, dir)
    toggled = active_exts.include?(ext) ? active_exts - [ ext ] : active_exts + [ ext ]
    files_path({ ext: toggled.presence&.join(","), sort:, dir: }.compact)
  end
```

- [ ] **Step 7: Create the chip row partial**

Create `app/views/files/_ext_filter.html.erb`:

```erb
<%#
  Filter the library by file type. Clicking a chip switches to a FLAT, whole-library list of that
  type; chips compose, so "all my STLs and 3MFs" is two clicks. Rendered in both modes, so a
  filter can be started from inside a folder (and immediately leaves it — see #index).
%>
<div class="ext-filter">
  <% FilesHelper::EXT_FAMILIES.each do |family, exts| %>
    <span class="ext-family" aria-label="<%= family %>">
      <span class="muted family-label"><%= family %></span>
      <% exts.each do |ext| %>
        <%= link_to ".#{ext}", ext_toggle_path(ext, @exts, @sort, @dir),
                    class: "chip#{' active' if @exts.include?(ext)}",
                    "aria-pressed": @exts.include?(ext).to_s %>
      <% end %>
    </span>
  <% end %>

  <%# Anything the curated list has never heard of (.f3d, .scad). One GET field; the controller
      joins add_ext onto ext, so there is still exactly one filter param. %>
  <form method="get" action="<%= files_path %>" class="ext-other">
    <% if @exts.any? %><input type="hidden" name="ext" value="<%= @exts.join(',') %>"><% end %>
    <input type="text" name="add_ext" placeholder="or an extension…" size="12"
           aria-label="Filter by another extension" pattern="[A-Za-z0-9]{1,8}">
    <button type="submit" class="linkbtn">Filter</button>
  </form>

  <% if @exts.any? %>
    <%= link_to "Clear filter", files_path(sort: @sort, dir: @dir), class: "muted clear-filter" %>
  <% end %>
</div>
```

- [ ] **Step 8: Render the chips, the notice and the flat empty state**

In `app/views/files/index.html.erb`, add immediately after the `<nav class="breadcrumb">…</nav>`
block:

```erb
<%= render "ext_filter" %>

<% if @truncated %>
  <p class="truncated">
    Showing the first <%= number_with_delimiter(@nodes.size) %> of
    <%= number_with_delimiter(@match_count) %> matching files — narrow the filter to see the rest.
  </p>
<% end %>
```

and change the empty-state line at the bottom from:

```erb
  <p class="empty muted">No files yet. Upload one to get started.</p>
```

to:

```erb
  <% if @flat %>
    <p class="empty muted">No files match <%= @exts.map { |e| ".#{e}" }.to_sentence %>.</p>
  <% else %>
    <p class="empty muted">No files yet. Upload one to get started.</p>
  <% end %>
```

- [ ] **Step 9: Add the Folder column to the list**

In `app/views/files/_list.html.erb`, add to the `<thead>` row immediately after the `Type` header:

```erb
      <% if @flat %><th>Folder</th><% end %>
```

and in the `<tbody>` row, immediately after the `<td class="muted"><%= node.kind %></td>` cell:

```erb
        <%# Where this file actually lives — a flat list without it is unnavigable. The link goes
            to that folder, so the flat view doubles as a way to FIND things. %>
        <% if @flat %>
          <td class="muted">
            <%= link_to (@folder_paths[node.node_id].presence || "Files"),
                        files_path(folder: node.parent_node_id) %>
          </td>
        <% end %>
```

- [ ] **Step 10: Style it**

Append to `app/assets/stylesheets/application.css`:

```css
.ext-filter { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin: 0 0 14px; }
.ext-family { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 4px; }
.ext-family .family-label { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
.ext-filter .chip { padding: 3px 10px; border: 1px solid var(--line); border-radius: 999px;
  font-size: 13px; color: var(--muted); }
.ext-filter .chip:hover { text-decoration: none; background: var(--soft); color: var(--fg); }
.ext-filter .chip.active { background: var(--accent); border-color: var(--accent); color: #fff; }
.ext-other { display: inline-flex; gap: 4px; align-items: center; }
.ext-other input { padding: 4px 8px; border: 1px solid var(--line); border-radius: 6px; }
.truncated { margin: 0 0 12px; padding: 8px 12px; border-radius: 6px;
  background: var(--soft); color: var(--muted); font-size: 13px; }
```

- [ ] **Step 11: Run until green**

```bash
bin/rails test test/integration/web/files_type_filter_test.rb
```

Expected: PASS, 14 runs, 0 failures, 0 errors.

- [ ] **Step 12: Run the whole web suite**

```bash
bin/rails test test/integration/web
```

Expected: 0 failures, 0 errors. `folder_nav_test.rb` is the one to watch — it asserts the folder
view's exact contents, and flat mode must not have changed it.

- [ ] **Step 13: Commit**

```bash
git add app/controllers/files_controller.rb app/helpers/files_helper.rb \
  app/views/files/_ext_filter.html.erb app/views/files/index.html.erb \
  app/views/files/_list.html.erb app/assets/stylesheets/application.css \
  test/integration/web/files_type_filter_test.rb
git commit -m "feat(files): flat by-extension filter across the whole library

?ext=stl,3mf lists every matching file at any depth, with a Folder column
so the result is navigable. Extensions are whitelisted to [a-z0-9]{1,8},
which is what bounds the OR-ed LIKE. Bounded at 2000 with an announced
truncation — a silent cut reads as 'that's all your STLs'.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Documentation

**Files:**
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Read the open-items list**

```bash
grep -n "Open\|open item" docs/STATUS.md | head -20
```

The Phase 4 follow-up recorded that a stale open-list is worse than none, so check whether anything
this branch closed is still listed there before adding to it.

- [ ] **Step 2: Add a short entry**

Add a dated bullet to `docs/STATUS.md` in the same voice as the entries around it, covering: the
attach dropdown + multi-project chips; `Maker::MoveNode` as the named home of the two-door move
(third copy, after `LibraryFolder` and `FilesController#destroy`); attach-relocates-on-first-project
with the rename-or-leave prompt; sortable columns (and **why the sort is in Ruby** — the §10
tripwire that rules out an `ext` column); and the flat extension filter with its announced 2000-row
bound (**the first bound this page has ever had**; the folder view stays unbounded).

- [ ] **Step 3: Commit**

```bash
git add docs/STATUS.md
git commit -m "docs(status): file organization and views

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: Full verification on all three backends

**Files:** none (fixes only if something is red).

- [ ] **Step 1: Lint**

```bash
bin/rubocop
```

Expected: no offenses. Autocorrect with `bin/rubocop -a` if it flags formatting, then re-run.

- [ ] **Step 2: The three legs**

```bash
bin/rails test
LIBRARY_BACKEND=share bin/rails test
LIBRARY_BACKEND=s3 bin/rails test
```

Expected: **identical** `N runs / M assertions / 0 failures / 0 errors` on all three, with N equal
to the Task 0 baseline plus the tests this branch added (10 + 5 + 8 + 8 + 10 + 14 = 55). A leg that
differs from the others is the signal this whole three-leg discipline exists for — do not paper over
it by pinning a backend in the failing test until you understand which adapter behaves differently
and why.

- [ ] **Step 3: Drive it in a browser**

```bash
bin/rails server -p 3000
```

Sign in and confirm by hand, because none of the above proves the page looks right:
1. `/files` — the chip row renders; clicking `.stl` gives a flat list with a Folder column; adding
   `.3mf` composes; "Clear filter" returns to the folder view.
2. Click Name, then Name again — the arrow flips and the order reverses. Switch to Grid; the sort
   selects show the same choice.
3. Open a file, attach it to a project from the dropdown — you land back on the file page, the
   project appears as a chip, and the file is now inside `Projects/<slug>/`.
4. Attach a second file with the same name to the same project — the dialog offers the `(2)` name;
   take it, and confirm the file lands in the folder renamed.
5. Attach a file that is already in another project — it must NOT move.

- [ ] **Step 4: Report**

Summarize: the three-leg counts, anything found by hand that the tests missed, and any spec
requirement that turned out to be wrong once running. Do not mark the plan complete on a green
suite alone — step 3 is the part that catches a view that renders but reads badly.
