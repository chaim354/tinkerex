# Auto Project Library Folders — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Auto-create a `Projects/<slug>/` library folder per project (across chunk/share/s3) and route project-view uploads into it.

**Architecture:** Add a `mkdir` verb to the `FileLayer` port (Share + S3 own their bytes; Chunk refuses — its tree is the sync engine's). A single `Maker::LibraryFolder` service walks a path segment-by-segment, branching once on `port_writable?` (→ `FileLayer.mkdir`) vs chunk (→ `Sync::Mutation.apply(op: "mkdir")`). Projects gain a `folder_node_id`; the upload flow resolves/ensures the folder and passes it as the upload parent.

**Tech Stack:** Rails 8, the existing `FileLayer` adapters + contracts, `Sync::Mutation`, Hotwire uploader.

**Branch:** `project-folders` (off `main`; the spec commit is its first commit).

**Spec:** `docs/superpowers/specs/2026-07-22-project-folders-design.md`

**Conventions:** conventional commits + the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer. Tests: `bin/rails test <path>`; the three backend legs are `bin/rails test`, `LIBRARY_BACKEND=share … LIBRARY_PATH=$(mktemp -d)`, `LIBRARY_BACKEND=s3 …`. Scoped `git add` (the tree carries unrelated boxes WIP).

**Reuse (do NOT reinvent):** Share/S3 both expose the private helpers `leaf!`, `join_rel(dir_rel, name)`, `parent_dir_rel!(user, parent_node_id)`, `observable!(rel)`, `resolve_inside!(rel)` (Share), `key_for_rel(rel)` (S3), `nanos(st_or_time)`. `mkdir` MUST go through the same guards as `write` or it re-opens the scan-wedge bug class the share adapter documents at length (`observable!`, `TEMP_PREFIX`).

---

## Task 1: `FileLayer::Share#mkdir`

**Files:**
- Modify: `app/services/file_layer/share.rb` (add `mkdir` near `write`)
- Test: `test/services/file_layer/share_test.rb` (or wherever share adapter tests live — mirror the existing `write` tests' setup)

- [ ] **Step 1: Write the failing test**

Mirror the existing share adapter test setup (`@root = Dir.mktmpdir`, `FileLayer::Share.new(root:)`, a `@user`). Add:

```ruby
test "mkdir creates a real directory + a dir node, and is idempotent" do
  info = @layer.mkdir(@user, parent_node_id: nil, name: "Projects")
  node = @user.nodes.find_by!(node_id: info.node_id)
  assert_equal "dir", node.kind
  assert_equal "Projects", node.storage_path
  assert Dir.exist?(File.join(@root, "Projects")), "the real directory must exist on the share"

  again = @layer.mkdir(@user, parent_node_id: nil, name: "Projects")
  assert_equal info.node_id, again.node_id, "mkdir is idempotent — same dir node, no duplicate"
  assert_equal 1, @user.nodes.where(kind: "dir", storage_path: "Projects").count
end

test "mkdir nests under a parent dir node" do
  root = @layer.mkdir(@user, parent_node_id: nil, name: "Projects")
  sub  = @layer.mkdir(@user, parent_node_id: root.node_id, name: "desk-lamp")
  assert_equal "Projects/desk-lamp", @user.nodes.find_by!(node_id: sub.node_id).storage_path
  assert Dir.exist?(File.join(@root, "Projects", "desk-lamp"))
end

test "mkdir refuses a reserved/unobservable name (would wedge the scan)" do
  assert_raises(FileLayer::NotFound) { @layer.mkdir(@user, parent_node_id: nil, name: ".trash") }
end

test "an empty mkdir'd folder survives a scan (path-reconcile keeps the dir node)" do
  info = @layer.mkdir(@user, parent_node_id: nil, name: "Projects")
  Library::Scanner.call(@user, root: @root, max_delete_pct: 100)
  node = @user.nodes.find_by(node_id: info.node_id)
  assert node && !node.deleted?, "the dir node must survive the scan (the real dir is on disk)"
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/services/file_layer/share_test.rb -e mkdir`
Expected: FAIL — `NoMethodError: undefined method 'mkdir'`.

- [ ] **Step 3: Implement `Share#mkdir`**

In `app/services/file_layer/share.rb`, after `write` (before `delete`), add:

```ruby
    # Create ONE directory `name` under `parent_node_id` (nil = library root). Reuses write's exact
    # guards — leaf!/observable!/resolve_inside! — because a mkdir that skips them re-opens the
    # scan-wedge bug class this file documents (a live node at a path no scan can pair). Idempotent:
    # a live dir already at this rel is returned, not duplicated (LibraryFolder walks paths and will
    # call this repeatedly). The real directory is created on disk so the next scan RECONCILES the
    # dir node by storage_path (Reconciler pairs dir nodes on path) — that is what makes an EMPTY
    # project folder survive, unlike a bare dir-node insert (which the scan would tombstone).
    def mkdir(user, parent_node_id: nil, name: nil)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      observable!(rel)
      existing = user.nodes.present.find_by(kind: "dir", storage_path: rel)
      return stat(user, node_id: existing.node_id) if existing

      dest = resolve_inside!(rel)
      raise UnsupportedOperation, "#{rel.inspect} already exists as a file" if dest.exist? && !dest.directory?
      begin
        FileUtils.mkdir_p(dest)
      rescue SystemCallError => e
        raise FetchError, "#{rel.inspect}: #{e.class} (#{e.message})"
      end
      node = user.nodes.create!(
        node_id: SecureRandom.uuid, name:, kind: "dir", deleted: false,
        storage_path: rel, parent_node_id:, mtime: nanos(File.stat(dest))
      )
      stat(user, node_id: node.node_id)
    end
```

- [ ] **Step 4: Run to verify pass**

Run: `bin/rails test test/services/file_layer/share_test.rb -e mkdir`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/file_layer/share.rb test/services/file_layer/share_test.rb
git commit -m "feat(folders): FileLayer::Share#mkdir (dir on disk + node, scan-survivable)"
```

---

## Task 2: `FileLayer::S3#mkdir`

**Files:**
- Modify: `app/services/file_layer/s3.rb`
- Test: `test/services/file_layer/s3_test.rb` (mirror the FakeS3 setup)

- [ ] **Step 1: Write the failing test**

Mirror the S3 adapter test setup (`@fake = FakeS3.new`, `FileLayer::S3.new(bucket:, prefix:, client: @fake.client)`, `@user`). Add:

```ruby
test "mkdir puts a dir-marker object + a dir node, idempotent" do
  info = @layer.mkdir(@user, parent_node_id: nil, name: "Projects")
  node = @user.nodes.find_by!(node_id: info.node_id)
  assert_equal "dir", node.kind
  assert_equal "Projects", node.storage_path
  assert @fake.exists?("#{PREFIX}/Projects/"), "an empty folder needs a dir-marker object to survive the scan"

  again = @layer.mkdir(@user, parent_node_id: nil, name: "Projects")
  assert_equal info.node_id, again.node_id
  assert_equal 1, @user.nodes.where(kind: "dir", storage_path: "Projects").count
end

test "an empty mkdir'd folder survives an S3 observer/reconciler pass" do
  info = @layer.mkdir(@user, parent_node_id: nil, name: "Projects")
  # Reconcile against the observed bucket (the dir-marker → dir, not a phantom file).
  Library::Reconciler.new(@user).call(FileLayer::S3::S3Observer.new(@layer).observe)  # adjust to the real observer API
  node = @user.nodes.find_by(node_id: info.node_id)
  assert node && !node.deleted?
end
```

*(Adjust the observer/reconciler invocation to match how `s3_library_test.rb` drives a scan — read it first.)*

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/services/file_layer/s3_test.rb -e mkdir`
Expected: FAIL — no `mkdir`.

- [ ] **Step 3: Implement `S3#mkdir`**

In `app/services/file_layer/s3.rb`, after `write`, add (mirrors Share#mkdir; the store difference is a trailing-slash marker key instead of a real directory):

```ruby
    # Create ONE directory under `parent_node_id`. On S3 a "directory" is a zero-byte dir-MARKER
    # object `<key>/` (the shape the console mints and S3Observer already reads as a dir, not a
    # phantom file) plus a dir node. The marker is what makes an EMPTY folder survive a scan: with
    # no object under the prefix the reconciler has nothing to pair the dir node to and tombstones
    # it. Reuses write's guards (leaf!/observable!). Idempotent.
    def mkdir(user, parent_node_id: nil, name: nil)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      observable!(rel)
      existing = user.nodes.present.find_by(kind: "dir", storage_path: rel)
      return stat(user, node_id: existing.node_id) if existing

      marker = "#{key_for_rel(rel)}/"
      begin
        @client.put_object(bucket: @bucket, key: marker, body: "")
        head = @client.head_object(bucket: @bucket, key: marker)
      rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
        raise FetchError, "#{rel.inspect}: #{e.class} (#{e.message})"
      end
      node = user.nodes.create!(
        node_id: SecureRandom.uuid, name:, kind: "dir", deleted: false,
        storage_path: rel, parent_node_id:, mtime: nanos(head.last_modified)
      )
      stat(user, node_id: node.node_id)
    end
```

**Before writing this:** read `s3.rb`'s `key_for_rel`, `nanos`, and how `s3_library_test.rb` seeds + scans, and confirm `FakeS3` supports `exists?` (add a helper if missing). Confirm `S3Observer` classifies a `foo/` key as a dir (grep for the dir-marker handling CLAUDE.md §3 describes).

- [ ] **Step 4–5: Run + commit**

Run: `bin/rails test test/services/file_layer/s3_test.rb -e mkdir` → PASS.
```bash
git add app/services/file_layer/s3.rb test/services/file_layer/s3_test.rb
git commit -m "feat(folders): FileLayer::S3#mkdir (dir-marker + node, scan-survivable)"
```

---

## Task 3: `Chunk#mkdir` refuses + contract coverage

**Files:**
- Modify: `app/services/file_layer/chunk.rb` (add `mkdir` that raises)
- Modify: `test/services/maker/previews/adapter_write_contract.rb` (or wherever `FileLayerWritableContract` lives) — add a `mkdir` shared test
- Modify: the read `adapter_contract.rb` if it pins per-capability behavior

- [ ] **Step 1: Add the chunk refusal + a write-contract shared test**

`Chunk#mkdir` (mirror `Chunk#write`'s refusal, naming the real door):

```ruby
    # Chunk tree mutations belong to the sync engine, not the port — mkdir goes through
    # Sync::Mutation.apply(op: "mkdir") (Maker::LibraryFolder / V1::NodesController#mkdir), never here.
    def mkdir(_user, parent_node_id: nil, name: nil)
      raise FileLayer::UnsupportedOperation,
            "chunk mkdir belongs to the sync engine: use Sync::Mutation.apply(op: \"mkdir\")"
    end
```

In the writable contract (runs against Share + S3), add:

```ruby
  test "#{adapter_label}: mkdir creates a navigable dir node and is idempotent" do
    a = adapter
    info = a.mkdir(user, parent_node_id: nil, name: "ContractDir")
    node = user.nodes.find_by!(node_id: info.node_id)
    assert_equal "dir", node.kind
    assert_equal info.node_id, a.mkdir(user, parent_node_id: nil, name: "ContractDir").node_id
  end
```

- [ ] **Step 2–4: Run both backend legs + commit**

Run: `bin/rails test` then `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test test/…adapter_write_contract…` then the s3 leg. Expected: PASS on Share + S3.
```bash
git add app/services/file_layer/chunk.rb test/…/adapter_write_contract.rb
git commit -m "feat(folders): mkdir on the write contract; Chunk#mkdir refuses (sync-engine door)"
```

---

## Task 4: `Maker::LibraryFolder.ensure_path!`

**Files:**
- Create: `app/services/maker/library_folder.rb`
- Create: `test/services/maker/library_folder_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"
module Maker
  class LibraryFolderTest < ActiveSupport::TestCase
    # Chunk branch: real chunk backend; folders created via Sync::Mutation (changelog entries).
    class ChunkBranch < LibraryFolderTest
      setup { pin_file_layer_backend("chunk"); Storage::ChunkStore.reset!
              @user = User.create!(email: "lf-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current, omniauth_signup: true) }

      test "ensure_path! creates nested dirs and is idempotent (chunk / sync-mutation)" do
        leaf = Maker::LibraryFolder.ensure_path!(@user, ["Projects", "desk-lamp"])
        assert_equal "dir", leaf.kind
        assert_equal "desk-lamp", leaf.name
        root = @user.nodes.present.find_by!(name: "Projects", parent_node_id: nil, kind: "dir")
        assert_equal root.node_id, leaf.parent_node_id
        assert @user.changelog_entries.exists?(op: "mkdir", node_id: leaf.node_id), "chunk mkdir → changelog"
        # idempotent: same nodes, no duplicates
        again = Maker::LibraryFolder.ensure_path!(@user, ["Projects", "desk-lamp"])
        assert_equal leaf.node_id, again.node_id
        assert_equal 1, @user.nodes.where(name: "Projects", parent_node_id: nil).count
      end
    end

    # Share branch: port_writable → FileLayer.mkdir.
    class ShareBranch < LibraryFolderTest
      setup { @root = Dir.mktmpdir("lf-share")
              FileLayer.current = FileLayer::Share.new(root: @root)
              @user = User.create!(email: "lfs-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current, omniauth_signup: true) }
      teardown { FileLayer.reset!; FileUtils.remove_entry(@root) if @root && File.exist?(@root) }

      test "ensure_path! walks via FileLayer.mkdir (share)" do
        leaf = Maker::LibraryFolder.ensure_path!(@user, ["Projects", "desk-lamp"])
        assert_equal "Projects/desk-lamp", leaf.storage_path
        assert Dir.exist?(File.join(@root, "Projects", "desk-lamp"))
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure** — `bin/rails test test/services/maker/library_folder_test.rb` → FAIL (no service).

- [ ] **Step 3: Implement the service**

Create `app/services/maker/library_folder.rb`:

```ruby
module Maker
  # Ensure a library folder path exists and return its leaf dir Node, find-or-creating each segment.
  # The ONE place the cross-backend folder-creation branch lives (controllers call this, never
  # Sync:: or the port's mkdir directly):
  #   port_writable? (share/s3) → FileLayer.current.mkdir per segment
  #   else (chunk)              → Sync::Mutation.apply(op: "mkdir") per segment (the sync-engine door)
  class LibraryFolder
    def self.ensure_path!(user, segments)
      new(user).ensure_path!(segments)
    end

    def initialize(user)
      @user = user
      @port_writable = FileLayer.current.capabilities.port_writable?
    end

    def ensure_path!(segments)
      parent = nil # nil = library root
      segments.each { |name| parent = ensure_segment(parent&.node_id, name) }
      parent
    end

    private

    def ensure_segment(parent_node_id, name)
      existing = @user.nodes.present.find_by(parent_node_id:, name:, kind: "dir")
      return existing if existing
      @port_writable ? port_mkdir(parent_node_id, name) : chunk_mkdir(parent_node_id, name)
    end

    def port_mkdir(parent_node_id, name)
      info = FileLayer.current.mkdir(@user, parent_node_id:, name:)
      @user.nodes.find_by!(node_id: info.node_id)
    end

    def chunk_mkdir(parent_node_id, name)
      node = @user.nodes.new(
        node_id: SecureRandom.uuid, parent_node_id:, name:, kind: "dir",
        deleted: false, mode: 0o755, mtime: (Time.current.to_f * 1e9).to_i
      )
      seq = Sync::Mutation.apply(user: @user, node:, op: "mkdir")
      LibraryChannel.broadcast_change(@user, seq)
      node
    end
  end
end
```

**Before writing:** confirm `Sync::Mutation.apply` returns a seq and accepts a `new` (unsaved) Node the way `V1::NodesController#mkdir` uses it (it calls `find_or_initialize_by(node_id:)` then `assign_attributes` then `apply`). If `apply` expects a persisted or specifically-shaped node, mirror the controller exactly.

- [ ] **Step 4: Run to verify pass** — `bin/rails test test/services/maker/library_folder_test.rb` → PASS. Also run the s3 leg on this file.

- [ ] **Step 5: Commit**
```bash
git add app/services/maker/library_folder.rb test/services/maker/library_folder_test.rb
git commit -m "feat(folders): Maker::LibraryFolder.ensure_path! (chunk sync-mutation | share/s3 port)"
```

---

## Task 5: `folder_node_id` on projects + ensure-on-create

**Files:**
- Create: a migration `db/migrate/…_add_folder_node_id_to_maker_projects.rb`
- Modify: `db/schema.rb` (via migrate)
- Modify: `app/models/maker/project.rb` (`ensure_library_folder!`)
- Modify: `app/controllers/projects_controller.rb#create` (best-effort ensure)
- Test: `test/integration/web/projects_flow_test.rb`

- [ ] **Step 1: Migration**

```ruby
class AddFolderNodeIdToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_projects, :folder_node_id, :string
  end
end
```
Run: `bin/rails db:migrate` (updates schema.rb). Also run on the test DB (`bin/rails db:test:prepare` if needed).

- [ ] **Step 2: Write the failing test** (add to `projects_flow_test.rb`, which pins chunk):

```ruby
test "creating a project ensures a Projects/<slug> library folder and stores its node_id" do
  user = sign_in
  post projects_path, params: { project: { name: "Desk Lamp", status: "planning" } }
  project = user.maker_projects.order(:created_at).last
  assert project.folder_node_id.present?, "the project's folder node_id must be stored"
  folder = user.nodes.present.find_by!(node_id: project.folder_node_id)
  assert_equal "dir", folder.kind
  assert_equal "desk-lamp", folder.name
  assert_equal "Projects", user.nodes.find_by!(node_id: folder.parent_node_id).name
end

test "project create still succeeds if the library backend can't make the folder" do
  user = sign_in
  # Force ensure to raise: stub FileLayer to a layer whose mkdir raises FetchError, or point chunk
  # at a broken store. Simplest: temporarily make ensure_library_folder! raise via a layer stub.
  FileLayer.current = Object.new.tap { |o| def o.capabilities; Struct.new(:port_writable?).new(true); end
                                          def o.mkdir(*); raise FileLayer::FetchError, "down"; end }
  assert_difference "Maker::Project.count", 1 do
    post projects_path, params: { project: { name: "Lamp", status: "planning" } }
  end
  assert_nil user.maker_projects.last.folder_node_id
ensure
  FileLayer.reset!
end
```

- [ ] **Step 3: Implement**

`app/models/maker/project.rb`:
```ruby
    # Return the project's library folder node, (re)creating Projects/<slug> if folder_node_id is
    # nil or points at a tombstoned/missing node (user deleted it in the browser). Best-effort at
    # create time (controller rescues); authoritative here at upload time.
    def ensure_library_folder!(acting_user)
      if folder_node_id.present?
        live = acting_user.nodes.present.find_by(node_id: folder_node_id, kind: "dir")
        return live if live
      end
      folder = Maker::LibraryFolder.ensure_path!(acting_user, [ "Projects", slug ])
      update_column(:folder_node_id, folder.node_id)
      folder
    end
```

`ProjectsController#create` — after a successful save, best-effort:
```ruby
    if @project.save
      begin
        @project.ensure_library_folder!(current_user)
      rescue FileLayer::FetchError, FileLayer::UnsupportedOperation, StandardError => e
        Rails.logger.warn("[projects] folder ensure failed: #{e.class} #{e.message}")
      end
      redirect_to project_path(@project), notice: "Project created."
    else
      render :new, status: :unprocessable_entity
    end
```
*(Keep the rescue narrow if possible — `FileLayer::FetchError` + the chunk transient; the broad `StandardError` is a backstop so folder creation NEVER fails project creation. Confirm which exceptions the chunk `Sync::Mutation` path can raise.)*

- [ ] **Step 4–5: Run + commit** — `bin/rails test test/integration/web/projects_flow_test.rb` → PASS. Run share + s3 legs.
```bash
git add db/migrate app/models/maker/project.rb app/controllers/projects_controller.rb \
  db/schema.rb test/integration/web/projects_flow_test.rb
git commit -m "feat(folders): projects get folder_node_id + ensure Projects/<slug> on create (best-effort)"
```

---

## Task 6: Uploads land in the project folder

**Files:**
- Modify: `app/controllers/projects/uploads_controller.rb` (share/s3: parent = folder)
- Modify: `app/javascript/controllers/uploader_controller.js` (send `parent_node_id`)
- Modify: `app/views/projects/_upload_control.html.erb` (chunk branch: `data-uploader-parent-value`)
- Modify: `app/controllers/projects_controller.rb#show` (ensure the folder so its node_id is fresh in the view) OR resolve in `_attachments`
- Test: `test/integration/web/project_upload_attach_test.rb`

- [ ] **Step 1: Write the failing tests**

Chunk (ChunkTest — the upload helper already exists; assert the node's parent):
```ruby
test "a project-view chunk upload lands in the project's folder" do
  project = @user.maker_projects.create!(name: "Lamp")   # ensure the folder
  folder = project.ensure_library_folder!(@user)
  # begin_upload with the folder as parent (what the uploader now sends)
  bytes = "solid\n".b; hash = Digest::SHA256.hexdigest(bytes)
  post begin_upload_files_path, params: { name: "p.stl", size: bytes.bytesize, parent_node_id: folder.node_id,
                                          manifest: [ { hash:, offset: 0, length: bytes.bytesize } ] }, as: :json
  begun = JSON.parse(response.body)
  (begun["put_urls"] || {}).each_value { |u| put u, params: bytes, headers: { "CONTENT_TYPE" => "application/octet-stream" } }
  post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
  assert_equal folder.node_id, @user.nodes.find_by(node_id: begun["node_id"]).parent_node_id
end
```

Share (ShareTest — POST to project_uploads, assert the written node's storage_path is under Projects/<slug>):
```ruby
test "a project-view share upload lands under Projects/<slug>" do
  project = @user.maker_projects.create!(name: "Lamp")
  file = Rack::Test::UploadedFile.new(StringIO.new("cube".b), "application/octet-stream", original_filename: "cube.stl")
  post project_uploads_path(project), params: { file: }
  node = @user.nodes.find_by!(node_id: project.file_attachments.last.node_id)
  assert_equal "Projects/lamp/cube.stl", node.storage_path
end
```

- [ ] **Step 2: Run to verify failure** — uploads still land at root.

- [ ] **Step 3: Implement**

`Projects::UploadsController#create` — resolve the folder and pass it as parent (only for the project target; entry-photo target stays at root per spec):
```ruby
    def create
      file = params.require(:file)
      target = attach_target
      parent = target.is_a?(Maker::BuildLogEntry) ? nil : project_of(target).ensure_library_folder!(current_user).node_id
      info = FileLayer.current.write(current_user, parent_node_id: parent, name: file.original_filename, io: file)
      …
```

`uploader_controller.js` — add a `parentNodeId` value and include it in the begin_upload body:
```javascript
  static values  = { beginUrl: String, finalizeUrl: String, attachUrl: String, redirectUrl: String, parentNodeId: String }
  …
      const begin = await this.postJSON(this.beginUrlValue, {
        name: file.name, size: bytes.length, manifest,
        parent_node_id: this.hasParentNodeIdValue ? this.parentNodeIdValue : null
      })
```

`_upload_control.html.erb` (chunk branch) — pass the parent. Its caller (`_attachments`) must supply it, so add a `parent_node_id:` local:
```erb
<%# in _attachments, render the control with the project folder as the upload parent %>
<%= render "upload_control", upload_url: project_uploads_path(@project),
           attach_url: project_attachments_path(@project), redirect_url: project_path(@project),
           parent_node_id: @project.ensure_library_folder!(current_user).node_id %>
```
and in `_upload_control` chunk branch add `data-uploader-parent-node-id-value="<%= parent_node_id %>"`.

*(Wrap the `ensure_library_folder!` call in the view in a rescue-to-nil so a backend blip doesn't 500 the project page — or ensure it in `#show` into an ivar with a rescue. Prefer the controller: set `@upload_parent_node_id` in `#show`, rescued.)*

- [ ] **Step 4: Run to verify pass** — all three backends. Run `project_upload_attach_test.rb` on chunk + share (+ s3).

- [ ] **Step 5: Commit**
```bash
git add app/controllers/projects/uploads_controller.rb app/javascript/controllers/uploader_controller.js \
  app/views/projects/_upload_control.html.erb app/views/projects/_attachments.html.erb \
  app/controllers/projects_controller.rb test/integration/web/project_upload_attach_test.rb
git commit -m "feat(folders): project-view uploads land in the project's Projects/<slug> folder"
```

---

## Task 7: Full-suite verification (3 backends)

- [ ] **Step 1:** `bin/rails test` → green.
- [ ] **Step 2:** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` → green.
- [ ] **Step 3:** `LIBRARY_BACKEND=s3 bin/rails test` → green.
- [ ] **Step 4:** Manual smoke (optional): create a project on the running app, upload a file from the project view, confirm it appears under `Projects/<slug>/` in the Files browser.
- [ ] **Step 5:** No commit (verification only) unless a fix was needed.

---

## Self-review checklist

- **Spec coverage:** port mkdir (Tasks 1–3), LibraryFolder service (Task 4), folder_node_id + ensure-on-create (Task 5), uploads-into-folder (Task 6), 3-backend tests throughout. Rename-follow, attach-existing relocation, entry-photo folder are Out of scope per spec.
- **Type consistency:** `mkdir(user, parent_node_id:, name:) -> FileInfo` (node_id) across Share/S3/Chunk; `LibraryFolder.ensure_path!(user, segments) -> Node`; `Project#ensure_library_folder!(user) -> Node`. Chunk mkdir refuses; the service never calls it (branches to Sync::Mutation).
- **Landmine check:** Share/S3 `mkdir` reuse `leaf!`/`observable!`/`resolve_inside!` — a mkdir bypassing these re-opens the scan-wedge class. The empty-folder-survives-scan tests (Tasks 1–2) are the guard.

## Execution handoff notes
- Deploy is Unraid-only ([[deploy-default-unraid-only]]); after merge, deploy the 3 Unraid backends.
- `Notes` is the next feature (separate spec/plan), per the user's ordering.
