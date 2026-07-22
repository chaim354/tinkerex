# Reusable File Chooser + Box Generator Save UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Box Generator's flat "Save to folder" `<select>` with a reusable, native-OS-style Miller-columns modal file chooser placed next to the Save button, and expose that chooser as a drop-in component for the rest of the web UI.

**Architecture:** A session-authed JSON endpoint (`LibraryBrowseController`) serves one folder's children + a folder-create, reading the shared `nodes` catalog and creating dirs through the existing `Maker::LibraryFolder` seam (backend-neutral; §10/§15 respected). A `filechooser` Stimulus controller builds the modal on demand and renders Miller columns from that JSON; a `shared/_folder_field` partial is the form trigger (button + hidden input). Box Generator is the first consumer.

**Tech Stack:** Rails 8 (server-rendered + JSON), Hotwire/Stimulus (importmap, eager-loaded controllers), Devise session auth, plain CSS (custom properties in `application.css`), Minitest.

---

## File Structure

**Create:**
- `app/controllers/library_browse_controller.rb` — session-authed JSON: `children` (GET) + `create_folder` (POST). ~55 lines.
- `app/javascript/controllers/filechooser_controller.js` — the modal + Miller columns + New Folder + mobile drill-down. ~185 lines.
- `app/views/shared/_folder_field.html.erb` — the form trigger partial (button + hidden input + controller wiring).
- `test/integration/web/library_browse_test.rb` — endpoint tests (backend-neutral, folder_nav_test.rb style).

**Modify:**
- `config/routes.rb` — two routes under the web-UI section.
- `app/services/maker/library_folder.rb` — add public `create_child!` (single-segment mkdir via the existing private `ensure_segment`).
- `app/views/tools/boxes/new.html.erb` — drop the `<select>`; render the trigger next to Save.
- `app/controllers/tools/boxes_controller.rb` — delete `folder_options` + the `@folders` assignment (dead after the view change; `chosen_parent_node_id` stays).
- `app/assets/stylesheets/application.css` — append `.folder-field*` + `.filechooser*` styles.
- `test/controllers/tools/boxes_controller_test.rb` — update the one picker test (the create tests are unchanged and must stay green).

**Conventions verified in this codebase:**
- Stimulus controllers are eager-loaded (`controllers/index.js` → `eagerLoadControllersFrom`), so a new `*_controller.js` auto-registers — no manual wiring.
- POST-from-JS reads the CSRF token from `meta[name="csrf-token"]` (see `boxpreview_controller.js`).
- Web endpoints are Devise session-authed (`before_action :authenticate_user!`) and user-scope every query (`current_user.nodes.present…`), never the device-token v1 API.
- CSS uses custom properties: `--fg #1c2230`, `--muted #6b7280`, `--line #e5e7eb`, `--bg #fff`, `--accent #2563eb`, `--soft #f7f8fa` (light theme; no dark theme in this app).
- `Node#children` = `user.nodes.present.where(parent_node_id: node_id)`; `Node#dir?` = `kind == "dir"`.

---

## Task 1: `Maker::LibraryFolder.create_child!` — single-segment mkdir seam

The New Folder endpoint must create one dir under an arbitrary parent without touching `Sync::`/the port directly (§10). `Maker::LibraryFolder` already owns that cross-backend branch in the **private** `ensure_segment`; expose a thin public wrapper.

**Files:**
- Modify: `app/services/maker/library_folder.rb`
- Test: `test/services/maker/library_folder_test.rb`

- [ ] **Step 1: Write the failing tests** — add one test to each existing branch class.

In `test/services/maker/library_folder_test.rb`, inside `class ChunkBranch < LibraryFolderTest`, after the existing `ensure_path!` test:

```ruby
      test "create_child! makes one dir under a parent, idempotently (chunk)" do
        parent = Maker::LibraryFolder.ensure_path!(@user, [ "Projects" ])
        child  = Maker::LibraryFolder.create_child!(@user, parent_node_id: parent.node_id, name: "desk-lamp")
        assert_equal "dir", child.kind
        assert_equal "desk-lamp", child.name
        assert_equal parent.node_id, child.parent_node_id
        assert @user.changelog_entries.exists?(op: "mkdir", node_id: child.node_id),
               "chunk mkdir must go through the sync engine"
        again = Maker::LibraryFolder.create_child!(@user, parent_node_id: parent.node_id, name: "desk-lamp")
        assert_equal child.node_id, again.node_id, "idempotent — find-or-create, no duplicate"
      end
```

Inside `class ShareBranch < LibraryFolderTest`, after its existing test:

```ruby
      test "create_child! makes one dir under a parent via the port (share)" do
        parent = Maker::LibraryFolder.ensure_path!(@user, [ "Projects" ])
        child  = Maker::LibraryFolder.create_child!(@user, parent_node_id: parent.node_id, name: "desk-lamp")
        assert_equal parent.node_id, child.parent_node_id
        assert Dir.exist?(File.join(@root, "Projects", "desk-lamp"))
      end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/maker/library_folder_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'create_child!' for Maker::LibraryFolder`.

- [ ] **Step 3: Implement `create_child!`**

In `app/services/maker/library_folder.rb`, add a class method beside `ensure_path!` and an instance method beside the existing `ensure_path!` instance method (keep `ensure_segment` private):

```ruby
    def self.create_child!(user, parent_node_id:, name:)
      new(user).create_child!(parent_node_id:, name:)
    end
```

and, in the instance-method section (above `private`):

```ruby
    # Create (or find) ONE child dir under `parent_node_id` (nil = library root). The single-segment
    # sibling of ensure_path!, for the chooser's "New Folder". Same cross-backend branch, one segment.
    def create_child!(parent_node_id:, name:)
      ensure_segment(parent_node_id, name)
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/maker/library_folder_test.rb`
Expected: PASS (all tests in the file green).

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/library_folder.rb test/services/maker/library_folder_test.rb
git commit -m "feat(library): Maker::LibraryFolder.create_child! — single-segment cross-backend mkdir"
```

---

## Task 2: `LibraryBrowseController#children` — folder-contents JSON

**Files:**
- Create: `app/controllers/library_browse_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/integration/web/library_browse_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, immediately after the `resources :files … end` block (before the `# --- Per-file notes` comment), add:

```ruby
  # --- Library browse (session-authed JSON; data source for the reusable folder/file chooser) ---
  get  "library/children", to: "library_browse#children",      as: :library_children
  post "library/folders",  to: "library_browse#create_folder", as: :library_folders
```

- [ ] **Step 2: Write the failing test**

Create `test/integration/web/library_browse_test.rb`:

```ruby
require "test_helper"

module Web
  # Session-authed JSON data source for the reusable folder/file chooser.
  #
  # DELIBERATELY NOT PINNED TO A BACKEND (like folder_nav_test.rb): it reads `nodes.parent_node_id`,
  # which all three backends populate identically, so seeding bare nodes and running on the ambient
  # LIBRARY_BACKEND proves it is backend-neutral. Must stay green on `bin/rails test`,
  # `LIBRARY_BACKEND=share`, and `LIBRARY_BACKEND=s3`.
  class LibraryBrowseTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "browse-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      # /Projects (dir) -> /Projects/v2 (dir) + /Projects/readme.txt (file)
      @projects = node("Projects", "dir", nil)
      @v2       = node("v2", "dir", @projects)
      @readme   = node("readme.txt", "file", @projects)
      @root_stl = node("root.stl", "file", nil)
    end

    def node(name, kind, parent)
      id = SecureRandom.uuid
      @user.nodes.create!(node_id: id, name:, kind:, parent_node_id: parent)
      id
    end

    def json = JSON.parse(response.body)

    test "children of the root lists root dirs only by default (no files)" do
      get library_children_path
      assert_response :success
      names = json["entries"].map { |e| e["name"] }
      assert_includes names, "Projects"
      assert_not_includes names, "root.stl", "files are omitted unless files=1"
      assert_nil json["parent"]
      assert_empty json["crumbs"]
    end

    test "children with files=1 includes files" do
      get library_children_path(files: 1)
      assert_response :success
      names = json["entries"].map { |e| e["name"] }
      assert_includes names, "Projects"
      assert_includes names, "root.stl"
    end

    test "children of a subfolder returns its children + a breadcrumb" do
      get library_children_path(parent: @projects, files: 1)
      assert_response :success
      assert_equal @projects, json["parent"]
      assert_equal %w[Projects], json["crumbs"].map { |c| c["name"] }
      names = json["entries"].map { |e| e["name"] }
      assert_includes names, "v2"
      assert_includes names, "readme.txt"
    end

    test "entries are dirs-first then name" do
      get library_children_path(parent: @projects, files: 1)
      kinds = json["entries"].map { |e| e["kind"] }
      assert_equal kinds.sort_by { |k| k == "dir" ? 0 : 1 }, kinds, "all dirs precede all files"
    end

    test "a foreign/forged parent falls back to the root, never another user's tree" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "Secret", kind: "dir")
      get library_children_path(parent: theirs.node_id)
      assert_response :success
      assert_nil json["parent"], "foreign parent resolved to root"
      assert_not_includes json["entries"].map { |e| e["name"] }, "Secret"
    end

    test "requires authentication" do
      delete destroy_user_session_path
      get library_children_path
      assert_redirected_to new_user_session_path
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/web/library_browse_test.rb`
Expected: FAIL — `uninitialized constant LibraryBrowseController` (route points at a missing controller).

- [ ] **Step 4: Implement the controller (children only)**

Create `app/controllers/library_browse_controller.rb`:

```ruby
# Session-authed, user-scoped JSON data source for the reusable folder/file chooser
# (app/javascript/controllers/filechooser_controller.js). NOT the device-token v1 API — this is the
# web UI. Reads the shared `nodes` catalog (backend-neutral: chunk/share/s3 all populate it) and
# creates folders through the one cross-backend seam, Maker::LibraryFolder. No bytes flow through
# here — metadata reads and dir-node creates only (§15).
class LibraryBrowseController < ApplicationController
  before_action :authenticate_user!

  # GET /library/children?parent=<node_id>&files=0|1 -> one folder's children as JSON:
  #   { parent: <id|null>, crumbs: [{node_id,name}…], entries: [{node_id,name,kind}…] }
  # A blank/foreign/stale `parent` resolves to the library root (never another user's tree) — the
  # same guard FilesController#current_folder uses. Folders always; files only when files=1.
  def children
    parent  = resolve_dir(params[:parent])
    scope   = current_user.nodes.present.where(parent_node_id: parent&.node_id)
    scope   = scope.where(kind: "dir") unless params[:files] == "1"
    entries = scope.to_a.sort_by { |n| [ n.dir? ? 0 : 1, n.name.downcase ] }
                   .map { |n| { node_id: n.node_id, name: n.name, kind: n.kind } }
    render json: { parent: parent&.node_id, crumbs: crumbs(parent), entries: entries }
  end

  private

  def resolve_dir(id)
    id.present? ? current_user.nodes.present.find_by(node_id: id, kind: "dir") : nil
  end

  # Root -> folder as [{node_id,name}], climbing parent_node_id with a cycle guard (mirrors
  # FilesController#folder_crumbs). Small duplication over a shared concern is deliberate here —
  # the walk is 6 lines and the two callers differ in param names and return shape.
  def crumbs(folder)
    out = []
    seen = Set.new
    node = folder
    while node && seen.add?(node.node_id)
      out.unshift(node_id: node.node_id, name: node.name)
      node = node.parent_node_id &&
             current_user.nodes.present.find_by(node_id: node.parent_node_id, kind: "dir")
    end
    out
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/integration/web/library_browse_test.rb`
Expected: PASS (all 6 tests green).

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/library_browse_controller.rb test/integration/web/library_browse_test.rb
git commit -m "feat(library-browse): GET /library/children — session-authed folder-contents JSON"
```

---

## Task 3: `LibraryBrowseController#create_folder` — New Folder JSON

**Files:**
- Modify: `app/controllers/library_browse_controller.rb`
- Test: `test/integration/web/library_browse_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `class LibraryBrowseTest` (before the final `end`s):

```ruby
    test "create_folder makes a dir under a parent and returns its node" do
      assert_difference -> { @user.nodes.present.where(kind: "dir").count }, 1 do
        post library_folders_path, params: { parent_node_id: @projects, name: "exports" }
      end
      assert_response :created
      created = @user.nodes.present.find_by(name: "exports", parent_node_id: @projects, kind: "dir")
      assert_equal created.node_id, json["node_id"]
      assert_equal "exports", json["name"]
      assert_equal "dir", json["kind"]
    end

    test "create_folder at the root uses a nil parent" do
      post library_folders_path, params: { name: "Top" }
      assert_response :created
      assert @user.nodes.present.exists?(name: "Top", parent_node_id: nil, kind: "dir")
    end

    test "create_folder rejects a duplicate name in the same folder" do
      assert_no_difference -> { @user.nodes.present.where(kind: "dir").count } do
        post library_folders_path, params: { parent_node_id: @projects, name: "v2" } # already exists
      end
      assert_response :unprocessable_entity
      assert_match(/already exists/i, json["error"])
    end

    test "create_folder rejects a blank name" do
      post library_folders_path, params: { parent_node_id: @projects, name: "  " }
      assert_response :unprocessable_entity
      assert_match(/blank/i, json["error"])
    end

    test "create_folder rejects a name containing a slash" do
      post library_folders_path, params: { name: "a/b" }
      assert_response :unprocessable_entity
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/integration/web/library_browse_test.rb`
Expected: FAIL — `AbstractController::ActionNotFound: … create_folder` (action not defined).

- [ ] **Step 3: Implement `create_folder`**

In `app/controllers/library_browse_controller.rb`, add the action after `children` (before `private`):

```ruby
  # POST /library/folders {parent_node_id, name} -> create ONE child dir, return its node JSON.
  # Powers the chooser's "New Folder". Goes through Maker::LibraryFolder so the cross-backend mkdir
  # branch stays in its one sanctioned place (§10). Duplicate/blank/reserved names -> 422 the modal
  # shows inline. `create_child!` is find-or-create, so the duplicate guard runs BEFORE it.
  def create_folder
    name   = params[:name].to_s.strip
    parent = resolve_dir(params[:parent_node_id])
    return folder_error("Folder name can't be blank.")  if name.blank?
    return folder_error("A folder name can't contain “/”.") if name.include?("/")
    if current_user.nodes.present.exists?(parent_node_id: parent&.node_id, name:, kind: "dir")
      return folder_error("A folder named “#{name}” already exists here.")
    end

    node = Maker::LibraryFolder.create_child!(current_user, parent_node_id: parent&.node_id, name:)
    render json: { node_id: node.node_id, name: node.name, kind: node.kind }, status: :created
  rescue FileLayer::NotFound
    folder_error("That folder name isn't allowed.") # a share/s3 backend rejected a reserved name
  end
```

and add to the `private` section:

```ruby
  def folder_error(message)
    render json: { error: message }, status: :unprocessable_entity
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/web/library_browse_test.rb`
Expected: PASS (all tests green, ~11 total).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/library_browse_controller.rb test/integration/web/library_browse_test.rb
git commit -m "feat(library-browse): POST /library/folders — New Folder (via Maker::LibraryFolder)"
```

---

## Task 4: `filechooser` Stimulus controller — the reusable modal

No JS unit-test harness exists in this repo (neither `boxpreview` nor `boxfilter` is JS-tested); this controller is covered by the endpoint tests (Tasks 2–3) + the box integration (Task 7) + the manual smoke in Task 8. Create the file with the exact content below.

**Files:**
- Create: `app/javascript/controllers/filechooser_controller.js`

- [ ] **Step 1: Create the controller**

Create `app/javascript/controllers/filechooser_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Reusable folder/file chooser — a native-OS-style Miller-columns modal, built on demand and
// appended to <body>. Data comes from a session-authed JSON endpoint (LibraryBrowseController).
// Used two ways: as a form field (writes the chosen node_id into a hidden input) and as a JS event
// source (fires `filechooser:choose` with {nodeId, kind, path}).
//
//   mode "folder": pick a destination folder. Descending a folder selects it; the root is always a
//                  valid selection; files are not shown. Footer verb "Choose".
//   mode "file":   pick an existing file. Folders navigate; a file click is the selection. "Open".
export default class extends Controller {
  static values = {
    mode: { type: String, default: "folder" },
    childrenUrl: String,
    createUrl: String,
    rootLabel: { type: String, default: "/ (library root)" },
    value: String,
    label: String,
  }
  static targets = ["button", "input"]

  connect() {
    this.cache = {}       // parentId ("" = root) -> entries array
    this.trail = []       // folders descended into (root implicit); each { id, name }
    this.selection = null // { nodeId, kind, path } or null
  }

  disconnect() { this.close() }

  // ---- open / close --------------------------------------------------------
  async open() {
    this.previouslyFocused = document.activeElement
    this.cache = {}
    this.trail = []
    this.selection = this.modeValue === "folder"
      ? { nodeId: (this.hasInputTarget && this.inputTarget.value) || "", kind: "dir", path: this.rootLabelValue }
      : null
    this.buildModal()
    await this.render()
    this.overlay.querySelector(".filechooser").focus()
  }

  close() {
    if (this.overlay) { this.overlay.remove(); this.overlay = null }
    if (this.onKeydown) { document.removeEventListener("keydown", this.onKeydown); this.onKeydown = null }
    if (this.previouslyFocused && this.previouslyFocused.focus) this.previouslyFocused.focus()
  }

  buildModal() {
    this.onKeydown = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this.onKeydown)

    const verb = this.modeValue === "file" ? "a file" : "a destination folder"
    this.overlay = document.createElement("div")
    this.overlay.className = "filechooser-overlay"
    this.overlay.innerHTML = `
      <div class="filechooser" role="dialog" aria-modal="true" aria-label="Choose ${verb}" tabindex="-1">
        <div class="filechooser-head"><span>Choose ${verb}</span>
          <button type="button" class="filechooser-close" aria-label="Close">✕</button></div>
        <div class="filechooser-crumbs"></div>
        <div class="filechooser-cols"></div>
        <div class="filechooser-foot">
          <div class="filechooser-newwrap"><button type="button" class="btn ghost filechooser-new">＋ New Folder</button></div>
          <div class="filechooser-actions">
            <button type="button" class="btn ghost filechooser-back" aria-label="Back">← Back</button>
            <span class="filechooser-sel"></span>
            <button type="button" class="btn ghost filechooser-cancel">Cancel</button>
            <button type="button" class="btn filechooser-choose">Choose</button>
          </div>
        </div>
      </div>`
    document.body.appendChild(this.overlay)

    this.colsEl = this.overlay.querySelector(".filechooser-cols")
    this.crumbsEl = this.overlay.querySelector(".filechooser-crumbs")
    this.selEl = this.overlay.querySelector(".filechooser-sel")
    this.chooseBtn = this.overlay.querySelector(".filechooser-choose")
    this.newWrap = this.overlay.querySelector(".filechooser-newwrap")

    this.overlay.addEventListener("click", (e) => { if (e.target === this.overlay) this.close() })
    this.overlay.querySelector(".filechooser-close").addEventListener("click", () => this.close())
    this.overlay.querySelector(".filechooser-cancel").addEventListener("click", () => this.close())
    this.overlay.querySelector(".filechooser-back").addEventListener("click", () => this.back())
    this.overlay.querySelector(".filechooser-new").addEventListener("click", () => this.newFolder())
    this.chooseBtn.addEventListener("click", () => this.choose())
    if (this.modeValue === "file") this.chooseBtn.textContent = "Open"
  }

  // ---- data ----------------------------------------------------------------
  async childrenOf(parentId) {
    const key = parentId || ""
    if (this.cache[key]) return this.cache[key]
    const url = new URL(this.childrenUrlValue, window.location.origin)
    if (parentId) url.searchParams.set("parent", parentId)
    if (this.modeValue === "file") url.searchParams.set("files", "1")
    let entries = []
    try {
      const res = await fetch(url, { headers: { Accept: "application/json" } })
      if (res.ok) entries = (await res.json()).entries || []
    } catch (_e) { /* transient; show an empty column */ }
    this.cache[key] = entries
    return entries
  }

  // ---- render --------------------------------------------------------------
  async render() {
    if (!this.overlay) return
    this.colsEl.innerHTML = ""
    const levels = [{ id: null, name: this.rootLabelValue }, ...this.trail]
    for (let k = 0; k < levels.length; k++) {
      const entries = await this.childrenOf(levels[k].id)
      const descendedId = this.trail[k] ? this.trail[k].id : null // folder opened FROM this column
      this.colsEl.appendChild(this.columnEl(entries, k, descendedId))
    }
    this.colsEl.scrollLeft = this.colsEl.scrollWidth
    this.crumbsEl.textContent = [this.rootLabelValue, ...this.trail.map((f) => f.name)].join("  ›  ")
    if (this.selection) {
      this.selEl.textContent = "Selected: " + this.selection.path
      this.chooseBtn.disabled = false
    } else {
      this.selEl.textContent = this.modeValue === "file" ? "Select a file" : ""
      this.chooseBtn.disabled = true
    }
  }

  columnEl(entries, depth, descendedId) {
    const col = document.createElement("div")
    col.className = "filechooser-col"
    if (entries.length === 0) {
      const empty = document.createElement("div")
      empty.className = "filechooser-empty"
      empty.textContent = "Empty folder"
      col.appendChild(empty)
    }
    for (const entry of entries) {
      const isFile = entry.kind !== "dir"
      const row = document.createElement("div")
      row.className = "filechooser-row" + (isFile ? " is-file" : "")
      const selected = (!isFile && entry.node_id === descendedId) ||
        (isFile && this.selection && this.selection.kind === "file" && this.selection.nodeId === entry.node_id)
      if (selected) row.classList.add("sel")
      row.textContent = (isFile ? "📄 " : "📁 ") + entry.name
      row.addEventListener("click", () => (isFile ? this.pickFile(depth, entry) : this.descend(depth, entry)))
      col.appendChild(row)
    }
    return col
  }

  // ---- navigation ----------------------------------------------------------
  descend(depth, folder) {
    this.trail = this.trail.slice(0, depth).concat([{ id: folder.node_id, name: folder.name }])
    this.selection = this.modeValue === "folder"
      ? { nodeId: folder.node_id, kind: "dir", path: this.pathFor(this.trail.length) }
      : null // in file mode, descending leaves nothing selected until a file is clicked
    this.render()
  }

  pickFile(depth, file) {
    this.trail = this.trail.slice(0, depth) // collapse any deeper folder columns
    this.selection = { nodeId: file.node_id, kind: "file", path: this.pathFor(depth) + "/" + file.name }
    this.render()
  }

  back() {
    if (this.trail.length === 0) return
    this.trail.pop()
    if (this.modeValue === "folder") {
      const last = this.trail[this.trail.length - 1]
      this.selection = last
        ? { nodeId: last.id, kind: "dir", path: this.pathFor(this.trail.length) }
        : { nodeId: "", kind: "dir", path: this.rootLabelValue }
    }
    this.render()
  }

  // "/" + the names of the first `n` descended folders (n counts levels below root).
  pathFor(n) {
    const parts = this.trail.slice(0, n).map((f) => f.name)
    return parts.length ? "/" + parts.join("/") : this.rootLabelValue
  }

  // ---- new folder ----------------------------------------------------------
  newFolder() {
    if (this.newWrap.querySelector("form")) return
    this.newWrap.innerHTML = `<form class="filechooser-newform">
      <input type="text" placeholder="Folder name" aria-label="New folder name" />
      <button type="submit" class="btn">Create</button>
      <span class="filechooser-newerr"></span></form>`
    const form = this.newWrap.querySelector("form")
    const input = form.querySelector("input")
    input.focus()
    form.addEventListener("submit", (e) => { e.preventDefault(); this.submitNewFolder(form, input) })
  }

  async submitNewFolder(form, input) {
    const name = input.value.trim()
    if (!name) return
    const parentId = this.trail.length ? this.trail[this.trail.length - 1].id : null
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const body = new FormData()
    body.set("name", name)
    if (parentId) body.set("parent_node_id", parentId)
    let res
    try {
      res = await fetch(this.createUrlValue, {
        method: "POST", body,
        headers: token ? { "X-CSRF-Token": token, Accept: "application/json" } : { Accept: "application/json" },
      })
    } catch (_e) {
      form.querySelector(".filechooser-newerr").textContent = "Network error."
      return
    }
    if (res.ok) {
      const node = await res.json()
      delete this.cache[parentId || ""] // this folder's listing is now stale
      this.resetNewButton()
      this.descend(this.trail.length, { node_id: node.node_id, name: node.name }) // step into the new folder
    } else {
      const err = await res.json().catch(() => ({}))
      form.querySelector(".filechooser-newerr").textContent = err.error || "Couldn't create folder."
    }
  }

  resetNewButton() {
    this.newWrap.innerHTML = `<button type="button" class="btn ghost filechooser-new">＋ New Folder</button>`
    this.newWrap.querySelector(".filechooser-new").addEventListener("click", () => this.newFolder())
  }

  // ---- commit --------------------------------------------------------------
  choose() {
    if (!this.selection) return
    const { nodeId, kind, path } = this.selection
    if (this.hasInputTarget) this.inputTarget.value = nodeId || ""
    if (this.hasButtonTarget) {
      const p = this.buttonTarget.querySelector(".ff-path")
      if (p) p.textContent = path
    }
    this.element.dispatchEvent(new CustomEvent("filechooser:choose", {
      bubbles: true, detail: { nodeId: nodeId || "", kind, path },
    }))
    this.close()
  }
}
```

- [ ] **Step 2: Verify it parses (asset build)**

Run: `bin/rails runner "puts 'ok'"`
Expected: `ok` (boots the app; no syntax gate for JS here — real verification is Task 8's browser smoke).

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/filechooser_controller.js
git commit -m "feat(filechooser): reusable Miller-columns modal chooser (Stimulus)"
```

---

## Task 5: `shared/_folder_field` trigger partial

**Files:**
- Create: `app/views/shared/_folder_field.html.erb`

- [ ] **Step 1: Create the partial**

Create `app/views/shared/_folder_field.html.erb`:

```erb
<%#
  Reusable folder/file chooser trigger. Renders a button (opens the modal built by the
  `filechooser` Stimulus controller) plus a hidden input carrying the chosen node_id for form
  submit. The controller also fires a `filechooser:choose` DOM event for JS consumers.

  Locals:
    name:         hidden input name (e.g. "parent_node_id")   [required]
    children_url: GET endpoint for a folder's children        [required]
    create_url:   POST endpoint to create a folder            [required]
    mode:         "folder" (default) or "file"
    value:        initial node_id (default nil)
    label:        initial button text (default root_label)
    root_label:   text for the library root (default "/ (library root)")
%>
<%
  name         = local_assigns.fetch(:name)
  children_url = local_assigns.fetch(:children_url)
  create_url   = local_assigns.fetch(:create_url)
  mode         = local_assigns.fetch(:mode, "folder")
  value        = local_assigns.fetch(:value, nil)
  root_label   = local_assigns.fetch(:root_label, "/ (library root)")
  label        = local_assigns.fetch(:label, root_label)
%>
<%= tag.span class: "folder-field",
      data: {
        controller: "filechooser",
        filechooser_mode_value: mode,
        filechooser_children_url_value: children_url,
        filechooser_create_url_value: create_url,
        filechooser_root_label_value: root_label,
        filechooser_value_value: value,
        filechooser_label_value: label
      } do %>
  <button type="button" class="folder-field-btn" data-action="filechooser#open"
          data-filechooser-target="button">
    <span aria-hidden="true">📁</span>
    <span class="ff-path"><%= label %></span>
    <span aria-hidden="true">▾</span>
  </button>
  <%= hidden_field_tag name, value, data: { filechooser_target: "input" } %>
<% end %>
```

> Note: write the two `aria-hidden` spans with the literal emoji/glyph — 📁 (folder) and ▾ (caret) — not the `\u…` escapes shown here (ERB does not interpret them). The escapes are only to keep this plan file ASCII.

- [ ] **Step 2: Commit**

```bash
git add app/views/shared/_folder_field.html.erb
git commit -m "feat(filechooser): shared/_folder_field trigger partial"
```

---

## Task 6: CSS — trigger button + modal

**Files:**
- Modify: `app/assets/stylesheets/application.css` (append at end; currently 213 lines)

- [ ] **Step 1: Append the styles**

Add to the end of `app/assets/stylesheets/application.css`:

```css

/* ---- Reusable folder/file chooser (filechooser_controller.js) ----------- */
.folder-field { display: inline-flex; }
.folder-field-btn {
  display: inline-flex; align-items: center; gap: 6px; max-width: 260px;
  padding: 8px 12px; border: 1px solid var(--line); border-radius: 8px;
  background: var(--bg); color: var(--fg); font: inherit; font-size: 14px; cursor: pointer;
}
.folder-field-btn:hover { border-color: var(--accent); }
.folder-field-btn .ff-path { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.filechooser-overlay {
  position: fixed; inset: 0; z-index: 1000; padding: 16px;
  background: rgba(17, 24, 39, 0.45);
  display: flex; align-items: center; justify-content: center;
}
.filechooser {
  display: flex; flex-direction: column; overflow: hidden;
  width: min(720px, 100%); max-height: min(560px, 90vh);
  background: var(--bg); color: var(--fg);
  border-radius: 12px; box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
}
.filechooser-head {
  display: flex; align-items: center; justify-content: space-between;
  padding: 12px 16px; border-bottom: 1px solid var(--line); font-weight: 600;
}
.filechooser-close { background: none; border: 0; font-size: 16px; color: var(--muted); cursor: pointer; }
.filechooser-crumbs {
  padding: 8px 16px; border-bottom: 1px solid var(--line);
  color: var(--muted); font-size: 13px; white-space: nowrap; overflow-x: auto;
}
.filechooser-cols { display: flex; flex: 1; min-height: 0; overflow-x: auto; }
.filechooser-col { flex: 0 0 200px; min-height: 0; overflow-y: auto; border-right: 1px solid var(--line); }
.filechooser-row {
  display: block; padding: 7px 12px; font-size: 14px; cursor: pointer;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.filechooser-row:hover { background: var(--soft); }
.filechooser-row.sel { background: var(--accent); color: #fff; }
.filechooser-row.is-file { color: var(--muted); }
.filechooser-row.sel.is-file { color: #fff; }
.filechooser-empty { padding: 10px 12px; color: var(--muted); font-size: 13px; }
.filechooser-foot {
  display: flex; align-items: center; justify-content: space-between; gap: 10px;
  padding: 12px 16px; border-top: 1px solid var(--line);
}
.filechooser-actions { display: flex; align-items: center; gap: 8px; }
.filechooser-sel { max-width: 240px; font-size: 13px; color: var(--muted);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.filechooser-back { display: none; } /* narrow screens only */
.filechooser-newform { display: flex; align-items: center; gap: 6px; }
.filechooser-newform input { padding: 6px 8px; border: 1px solid var(--line); border-radius: 6px; font: inherit; }
.filechooser-newerr { color: var(--danger); font-size: 12px; }

@media (max-width: 640px) {
  .filechooser-col { flex-basis: 100%; }
  .filechooser-col:not(:last-child) { display: none; } /* single-column drill-down */
  .filechooser-back { display: inline-flex; }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/assets/stylesheets/application.css
git commit -m "style(filechooser): trigger button + Miller-columns modal styles"
```

---

## Task 7: Box Generator rewire (view + controller + test)

**Files:**
- Modify: `app/views/tools/boxes/new.html.erb`
- Modify: `app/controllers/tools/boxes_controller.rb`
- Test: `test/controllers/tools/boxes_controller_test.rb`

- [ ] **Step 1: Update the picker test (write the new expectation first)**

In `test/controllers/tools/boxes_controller_test.rb`, replace the test at lines ~109–115 (`"new offers a folder picker: the library root plus existing folders"`) with:

```ruby
    test "new renders the reusable folder-chooser trigger, not a flat select" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "Projects", kind: "dir")
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select "select[name='parent_node_id']", count: 0 # the flat picker is gone
      assert_select ".folder-field[data-controller='filechooser'] " \
                    "input[type=hidden][name='parent_node_id']"
      assert_select ".folder-field-btn[data-action='filechooser#open']"
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/reusable folder-chooser trigger/"`
Expected: FAIL — the view still renders `<select name='parent_node_id'>`, and no `.folder-field` exists.

- [ ] **Step 3: Update the box `new` view**

In `app/views/tools/boxes/new.html.erb`, delete this block (the `Name` label stays; remove only the `Save to folder` label):

```erb
    <label class="box-field">
      <span class="box-field-label">Save to folder</span>
      <%= select_tag :parent_node_id, options_for_select(@folders) %>
    </label>
```

Then replace the `.page-actions` block:

```erb
    <div class="page-actions">
      <button type="button" data-action="boxpreview#preview" class="btn ghost">Preview</button>
      <button type="submit" class="btn">Save to library</button>
    </div>
```

with:

```erb
    <div class="page-actions">
      <button type="button" data-action="boxpreview#preview" class="btn ghost">Preview</button>
      <span class="box-field-label" style="margin-left:auto">Saving to</span>
      <%= render "shared/folder_field", name: "parent_node_id", mode: "folder",
                 value: nil, label: "/ (library root)",
                 children_url: library_children_path, create_url: library_folders_path %>
      <button type="submit" class="btn">Save to library</button>
    </div>
```

- [ ] **Step 4: Remove the dead controller code**

In `app/controllers/tools/boxes_controller.rb`:

Delete the `@folders = folder_options` line in `new` (the comment `# where to save the output …` on that line goes too):

```ruby
      @values = params[:params]&.to_unsafe_h || {} # optional prefill (e.g. "duplicate & tweak")
      @folders = folder_options # where to save the output (existing folders + root)
```

becomes:

```ruby
      @values = params[:params]&.to_unsafe_h || {} # optional prefill (e.g. "duplicate & tweak")
```

Delete the entire `folder_options` private method (the `# Existing folders to offer …` comment block plus the method body). Leave `chosen_parent_node_id` intact — `create` still uses it.

- [ ] **Step 5: Run the box tests (whole file)**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb`
Expected: PASS — the updated trigger test passes; `"create saves the bundle into the chosen folder"` and `"create ignores a parent_node_id that is not the user's own live folder"` still pass unchanged (the save path is untouched).

- [ ] **Step 6: Commit**

```bash
git add app/views/tools/boxes/new.html.erb app/controllers/tools/boxes_controller.rb test/controllers/tools/boxes_controller_test.rb
git commit -m "feat(boxes): destination chooser next to Save; drop the flat folder <select>"
```

---

## Task 8: Full-suite verification + manual browser smoke

**Files:** none (verification only)

- [ ] **Step 1: Run the full server suite**

Run: `bin/rails test`
Expected: PASS (0 failures, 0 errors). Note the run count.

- [ ] **Step 2: Run the share + s3 backend legs (the chooser must be backend-neutral)**

Run: `LIBRARY_BACKEND=share bin/rails test test/integration/web/library_browse_test.rb test/controllers/tools/boxes_controller_test.rb test/services/maker/library_folder_test.rb`
Expected: PASS.

Run: `LIBRARY_BACKEND=s3 bin/rails test test/integration/web/library_browse_test.rb test/controllers/tools/boxes_controller_test.rb test/services/maker/library_folder_test.rb`
Expected: PASS.

- [ ] **Step 3: Manual browser smoke (the JS controller's real coverage)**

Boot the app (`STORAGE_BACKEND=memory bin/rails server -p 3001`), sign in, seed a couple of folders (via the Files UI or `bin/rails console`), then open `/tools/boxes` → pick a generator → on the editor:

- [ ] The destination button sits **next to "Save to library"** and reads `📁 / (library root) ▾`.
- [ ] Clicking it opens the modal; the root column lists folders (no files).
- [ ] Clicking a folder opens its children in a new column to the right; the breadcrumb updates.
- [ ] **New Folder** creates a folder, steps into it, and it appears; a duplicate name shows the inline error.
- [ ] **Choose** closes the modal and the button now shows the chosen path; submitting the form saves the box and the bundle lands in that folder (verify on the saved-box page / Files browser).
- [ ] Narrow the window below ~640px: the modal shows a single column with a **← Back** control that walks up.
- [ ] Esc, backdrop click, and Cancel all close without changing the destination.

- [ ] **Step 4: Final commit (if any doc/status tweak is needed)**

If `docs/STATUS.md` or `MEMORY.md` mentions the box save UI, update it. Otherwise no commit needed here.

---

## Self-Review notes (already reconciled)

- **Spec coverage:** dual-mode (folder now, file built-in) → Task 4 `mode`; Miller columns + mobile drill-down → Task 4 + Task 6 media query; modal built on demand → Task 4 `buildModal`; New Folder via the one seam → Task 1 + Task 3; trigger next to Save → Task 7; generic session-authed endpoint → Tasks 2–3; result contract (hidden input + `filechooser:choose`) → Task 4 `choose`; backend-neutral / no gating → Tasks 2/3/8; §10/§15 respected → Task 1 seam + metadata-only endpoints.
- **Type consistency:** JSON keys `node_id`/`name`/`kind`/`parent`/`crumbs`/`entries` and `error` are identical across the controller (Tasks 2–3), the tests, and the JS (`entry.node_id`, `entry.kind`, `err.error`). Stimulus value names (`childrenUrlValue`, `createUrlValue`, `rootLabelValue`, `modeValue`) match the partial's `data-filechooser-*-value` attributes (Task 5). Path helpers `library_children_path` / `library_folders_path` match the `as:` route names (Task 2).
- **Placeholders:** none — every step has full code/commands. The only intentional non-literal is the `\u…` glyphs in the ERB partial, called out explicitly with the literal characters to type.
```
