# 3D View Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the interactive 3D viewer opt-in (a "View in 3D" button, no auto-loading) and add a dropdown to switch between a model's several 3D files.

**Architecture:** Extend the existing `modelviewer_controller.js` Stimulus controller with a `lazy` mode (don't boot on connect), an on-demand `load()` action, live source-switching, and a `showPoster()` teardown. Two host views mount that same controller: the model detail page gets a control bar (dropdown + button) over its hero; the file detail page's existing `:model3d` viewer becomes button-gated. No server/storage changes — everything routes through the existing `blob_file_path` byte endpoint, so it works identically on the chunk / share / s3 backends.

**Tech Stack:** Rails 8 (ERB views, integration tests via `ActionDispatch::IntegrationTest` + `assert_select`), Stimulus + importmap (Three.js via dynamic import — no JS bundler or JS test harness in this repo), plain CSS.

---

## Background the implementer needs

- **The viewer that already exists:** `app/javascript/controllers/modelviewer_controller.js` parses STL/3MF/OBJ bytes client-side and renders a WebGL scene. Today it **boots on `connect()`** — it fetches the model bytes and dynamically imports Three.js (~2 MB) the instant its element appears. Its graceful-degradation contract: any failure leaves a poster (the `fallback` target) visible; the `model-viewer--ready` class — added only on a successful first render — is what reveals the canvas and hides the poster (see `app/assets/stylesheets/application.css`).
- **Formats:** only STL / 3MF / OBJ can be parsed client-side. STEP/STP/IGES/IGS are `role: "model"` attachments too, but the viewer cannot render them — they stay as static server thumbnails. Filter by **file extension**, which is the source of truth for "the viewer can parse it" (`Maker::FileAttachment.role_for` maps `stl/3mf/obj/step/stp → "model"`, so role alone is too coarse).
- **`blob_file_path(node_id)`** → `GET /files/:id/blob`, the byte endpoint every preview uses; available as a URL helper in integration tests. Backend-agnostic (redirect-to-presigned / send_file / stream).
- **Two host views:** `app/views/models/show.html.erb` (the `.model-hero` block, ~lines 28-40) and `app/views/files/show.html.erb` (the `:model3d` branch, ~lines 62-85).
- **Model → files:** `Maker::Model has_many :file_attachments (order(:position))`. `ModelsController#show` already builds `@attachments` (ordered), `@nodes` (node_id → live Node, carrying `.name`), and `@cover_node_id` via `@model.cover_node_id`.
- **No JS test harness:** the repo is importmap-only (no `package.json`, no jest/vitest). JS behavior is verified by loading the page in a browser (Task 5), the same way the current viewer is verified. The Rails integration tests assert the **server-rendered markup** (data attributes, presence of the dropdown/button), which is the automatable part.
- **Test conventions** (from `test/integration/web/models_flow_test.rb` and `files_flow_test.rb`): `setup` pins a backend with `pin_file_layer_backend("chunk")` + `Storage::ChunkStore.reset!`; a `sign_in` helper; models get files via `user.nodes.create!(node_id:, name:, kind: "file", parent_node_id:)` + `m.file_attachments.create!(user:, node_id:, role:)`; `files_flow_test.rb` has an `upload(name, bytes) -> node_id` helper that round-trips real bytes so `preview_kind` returns `:model3d`. Assertions use `assert_select`.

## File structure

| File | Responsibility | Change |
|---|---|---|
| `app/javascript/controllers/modelviewer_controller.js` | The WebGL viewer (canvas, Three.js, orbit, dims, reset, fullscreen) + its lifecycle | Add `lazy` value, `load()`, `selectSource()`, `showPoster()`, extract `teardown()` |
| `app/assets/stylesheets/application.css` | Viewer + control-bar styling and `--ready` state visibility | Make the bar persistent; add dropdown + launch/actions cluster rules |
| `app/views/files/show.html.erb` | File detail preview | `:model3d` branch → `lazy` + "View in 3D" button |
| `app/controllers/models_controller.rb` | Model detail data | Add `@viewable_3d` + `@viewable_3d_default` |
| `app/views/models/_hero_poster.html.erb` | The static hero content (image / thumb / placeholder), reused as the poster | **New** partial (extracted from `show.html.erb`) |
| `app/views/models/show.html.erb` | Model detail page | Hero → viewer + control bar when 3D files exist |
| `test/integration/web/files_flow_test.rb` | File-page markup tests | Update the STL-viewer test for the lazy/button markup |
| `test/integration/web/models_flow_test.rb` | Model-page markup tests | Add multi / single / none / STEP-excluded tests |

---

## Task 1: Make the viewer lazy, on-demand, and switchable (JS controller)

**Files:**
- Modify (full rewrite): `app/javascript/controllers/modelviewer_controller.js`

**Why no test here:** there is no JS test harness in this repo (importmap, no bundler). This controller is exercised manually in Task 5. The change is behavior-preserving for the existing (non-lazy) file page until Task 3 sets `lazy`.

- [ ] **Step 1: Replace the controller with the lazy + switchable version**

Write `app/javascript/controllers/modelviewer_controller.js` with exactly this content:

```javascript
import { Controller } from "@hotwired/stimulus"

// Interactive 3D viewer for the mesh formats a print library is made of (STL / 3MF / OBJ).
// Parses the raw model bytes CLIENT-SIDE — no server conversion — and renders a manipulable
// WebGL scene. Three.js (~2MB unminified core) is pulled via a DYNAMIC import in boot() so it
// ships only on pages that actually contain a 3D file, not site-wide (Stimulus eager-imports
// controller MODULES at startup, so a top-level `import` would load Three everywhere).
//
// `lazy` defers the whole boot (and therefore the Three.js download + the byte fetch) until the
// user clicks "View in 3D" (load()). A `source` <select> lets one viewer switch between several
// model files. Graceful degradation is the contract: any failure (no WebGL, import error,
// fetch/CORS failure, corrupt file) leaves the server-rendered thumbnail poster visible. The
// `--ready` class, added only on a successful render, reveals the canvas and hides that poster.
export default class extends Controller {
  static values = { url: String, format: String, lazy: Boolean }
  static targets = ["canvas", "dims", "fallback", "source"]

  async connect() {
    this.disposed = false
    if (this.lazyValue) return // wait for load()
    try {
      await this.boot()
    } catch (e) {
      console.warn("[modelviewer] keeping thumbnail fallback:", e)
    }
  }

  disconnect() {
    this.disposed = true
    this.teardown()
  }

  // Free every GPU/DOM resource the current scene holds, WITHOUT marking the controller disposed —
  // so a later boot() (a file switch, or re-opening after showPoster) can start clean. Reused by
  // disconnect(), showPoster(), and the switch path in load().
  teardown() {
    if (this.frame) cancelAnimationFrame(this.frame)
    this.resizeObserver?.disconnect()
    this.controls?.dispose()
    this.scene?.traverse((o) => {
      o.geometry?.dispose?.()
      if (o.material) [].concat(o.material).forEach((m) => m.dispose?.())
    })
    if (this.renderer) {
      this.renderer.dispose()
      this.renderer.domElement?.remove()
    }
    this.frame = this.resizeObserver = this.controls = null
    this.scene = this.camera = this.renderer = this.home = null
  }

  // "View in 3D" (and the file-switch path): resolve the active source, tear down any current
  // scene, then boot. On failure fall back to the poster.
  async load() {
    if (this.hasSourceTarget && this.sourceTarget.selectedOptions.length) {
      const opt = this.sourceTarget.selectedOptions[0]
      this.urlValue = opt.dataset.url
      this.formatValue = opt.dataset.format
    }
    if (this.renderer) this.teardown() // switching files
    try {
      await this.boot()
    } catch (e) {
      console.warn("[modelviewer] keeping thumbnail fallback:", e)
      this.element.classList.remove("model-viewer--ready")
    }
  }

  // Dropdown change: live-switch only while the viewer is already showing; otherwise the choice is
  // simply read the next time the user clicks "View in 3D".
  selectSource() {
    if (this.element.classList.contains("model-viewer--ready")) this.load()
  }

  // "✕ Image": drop the scene (frees GPU memory, stops the render loop) and reveal the poster.
  showPoster() {
    this.teardown()
    this.element.classList.remove("model-viewer--ready")
  }

  async boot() {
    const THREE = await import("three")
    const { OrbitControls } = await import("three/addons/controls/OrbitControls.js")

    // Same-origin request; may 302 to a presigned cross-origin URL on s3/chunk-over-S3, which
    // needs bucket CORS — if it's not set the fetch rejects here and we fall back cleanly.
    const res = await fetch(this.urlValue, { credentials: "same-origin" })
    if (!res.ok) throw new Error(`fetch ${res.status}`)
    const buf = await res.arrayBuffer()

    const object = await this.parse(THREE, buf)

    const stage = this.canvasTarget
    const width = stage.clientWidth || 640
    const height = stage.clientHeight || 420

    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(0xf7f8fa)

    // Center the model at the origin and read its size for the dimensions label + camera framing.
    const box = new THREE.Box3().setFromObject(object)
    const size = box.getSize(new THREE.Vector3())
    const center = box.getCenter(new THREE.Vector3())
    object.position.sub(center)
    this.scene.add(object)
    this.showDims(size)

    const maxDim = Math.max(size.x, size.y, size.z) || 1
    this.camera = new THREE.PerspectiveCamera(45, width / height, maxDim / 100, maxDim * 100)
    this.camera.position.set(maxDim * 1.4, maxDim * 1.0, maxDim * 1.6)

    this.renderer = new THREE.WebGLRenderer({ antialias: true })
    this.renderer.setPixelRatio(window.devicePixelRatio)
    this.renderer.setSize(width, height)
    stage.appendChild(this.renderer.domElement)

    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 1.0))
    const key = new THREE.DirectionalLight(0xffffff, 1.4)
    key.position.set(1, 1, 1)
    this.scene.add(key)

    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.enableDamping = true
    this.controls.target.set(0, 0, 0)
    this.controls.update()
    this.home = { pos: this.camera.position.clone(), target: this.controls.target.clone() }

    this.resizeObserver = new ResizeObserver(() => this.resize())
    this.resizeObserver.observe(stage)

    this.element.classList.add("model-viewer--ready")
    this.animate()
  }

  async parse(THREE, buf) {
    const surface = () =>
      new THREE.MeshStandardMaterial({ color: 0x8899aa, metalness: 0.1, roughness: 0.8 })

    switch (this.formatValue) {
      case "stl": {
        const { STLLoader } = await import("three/addons/loaders/STLLoader.js")
        const geometry = new STLLoader().parse(buf)
        geometry.computeVertexNormals()
        return new THREE.Mesh(geometry, surface())
      }
      case "3mf": {
        const { ThreeMFLoader } = await import("three/addons/loaders/3MFLoader.js")
        return new ThreeMFLoader().parse(buf) // respects embedded units/materials
      }
      case "obj": {
        const { OBJLoader } = await import("three/addons/loaders/OBJLoader.js")
        const group = new OBJLoader().parse(new TextDecoder().decode(buf))
        group.traverse((o) => { if (o.isMesh) o.material = surface() }) // no .mtl -> neutral surface
        return group
      }
      default:
        throw new Error(`unsupported format ${this.formatValue}`)
    }
  }

  // STL/OBJ are unitless -> mm by the 3D-print convention; 3MF carries its own unit (applied by
  // the loader). Round to 0.1 for a readable bounding-box size.
  showDims(size) {
    if (!this.hasDimsTarget) return
    const mm = (n) => (Math.round(n * 10) / 10).toLocaleString()
    this.dimsTarget.textContent = `${mm(size.x)} × ${mm(size.y)} × ${mm(size.z)} mm`
  }

  resize() {
    if (!this.renderer || this.disposed) return
    const stage = this.canvasTarget
    const width = stage.clientWidth || 640
    const height = stage.clientHeight || 420
    this.camera.aspect = width / height
    this.camera.updateProjectionMatrix()
    this.renderer.setSize(width, height)
  }

  animate() {
    if (this.disposed || !this.renderer) return
    this.frame = requestAnimationFrame(() => this.animate())
    this.controls.update()
    this.renderer.render(this.scene, this.camera)
  }

  reset() {
    if (!this.home) return
    this.camera.position.copy(this.home.pos)
    this.controls.target.copy(this.home.target)
    this.controls.update()
  }

  fullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else {
      this.element.requestFullscreen?.()
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/javascript/controllers/modelviewer_controller.js
git commit -m "feat(3d-view): lazy load + file-switch + showPoster in modelviewer controller"
```

---

## Task 2: Control-bar CSS (resting vs. loaded states)

**Files:**
- Modify: `app/assets/stylesheets/application.css` (the `.model-viewer` block, ~lines 91-105)

The bar must now be visible **before** boot (to show "View in 3D"). Make `.model-viewer-bar` persistent, keep the dropdown visible in both states, and toggle a `.mv-launch` cluster (resting) vs. a `.mv-actions` cluster (loaded) on `--ready`.

> Note: the two host views adopt the `.mv-launch` / `.mv-actions` / `.model-viewer-source` classes in Tasks 3-4. Until then the old file-page markup shows its buttons unstyled by these rules — an expected one-commit cosmetic transient on the branch, not a failure.

- [ ] **Step 1: Replace the persistent-bar line**

In `app/assets/stylesheets/application.css`, replace this line:

```css
.model-viewer-bar { display: none; align-items: center; justify-content: space-between; gap: 12px; margin-top: 8px; }
```

with:

```css
.model-viewer-bar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 8px; flex-wrap: wrap; }
.model-viewer-source { font: inherit; padding: 4px 8px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); max-width: 60%; }
.mv-launch { display: inline-flex; gap: 8px; }
.mv-actions { display: none; gap: 8px; }
```

- [ ] **Step 2: Update the `--ready` state rules**

In the same file, replace this block:

```css
.model-viewer--ready .model-viewer-stage { display: block; }
.model-viewer--ready .model-viewer-bar { display: flex; }
.model-viewer--ready .model-viewer-fallback { display: none; }
```

with:

```css
.model-viewer--ready .model-viewer-stage { display: block; }
.model-viewer--ready .model-viewer-fallback { display: none; }
.model-viewer--ready .mv-launch { display: none; }
.model-viewer--ready .mv-actions { display: inline-flex; }
```

(The `.model-viewer-bar { display: flex }` when-ready rule is gone because the bar is now always flex.)

- [ ] **Step 3: Commit**

```bash
git add app/assets/stylesheets/application.css
git commit -m "style(3d-view): persistent control bar with resting/loaded clusters"
```

---

## Task 3: Gate the file-detail viewer behind a button (TDD)

**Files:**
- Test: `test/integration/web/files_flow_test.rb` (update the existing STL-viewer test, ~lines 216-228)
- Modify: `app/views/files/show.html.erb` (the `:model3d` branch, ~lines 62-85)

- [ ] **Step 1: Update the failing test**

In `test/integration/web/files_flow_test.rb`, replace the test `"an STL detail page renders the interactive 3D viewer container"` (currently ~lines 216-228) with:

```ruby
    test "an STL detail page renders the 3D viewer button-gated (lazy), not auto-loading" do
      sign_in
      node_id = upload("bracket.stl", "solid bracket\nendsolid\n".b)

      get file_path(node_id)
      assert_response :success
      assert_select ".model-viewer[data-controller=?]", "modelviewer"
      assert_select ".model-viewer[data-modelviewer-url-value=?]", blob_file_path(node_id)
      assert_select ".model-viewer[data-modelviewer-format-value=?]", "stl"
      # Button-gated: the viewer waits for a click instead of fetching bytes on load.
      assert_select ".model-viewer[data-modelviewer-lazy-value=?]", "true"
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
      # The reset/fullscreen/show-image controls are wired.
      assert_select "[data-action~=?]", "modelviewer#reset"
      assert_select "[data-action~=?]", "modelviewer#fullscreen"
      assert_select "[data-action~=?]", "modelviewer#showPoster"
    end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/integration/web/files_flow_test.rb -n "/3D viewer button-gated/"
```
Expected: FAIL — no element has `data-modelviewer-lazy-value="true"` / `modelviewer#load` yet.

- [ ] **Step 3: Update the `:model3d` branch of the view**

In `app/views/files/show.html.erb`, replace the `<% elsif @kind == :model3d %>` block (the `<div class="model-viewer" …>` … `</div>`, ~lines 62-85) with:

```erb
  <% elsif @kind == :model3d %>
    <%# Interactive client-side 3D viewer (Three.js), see modelviewer_controller.js. `lazy` gates
        the byte fetch + Three.js download behind the "View in 3D" button, so nothing heavy loads
        unless the user asks. The fallback (thumbnail poster + download) is the resting state and
        also the graceful-degradation target if the viewer can't boot. %>
    <div class="model-viewer"
         data-controller="modelviewer"
         data-modelviewer-lazy-value="true"
         data-modelviewer-url-value="<%= blob_file_path(@node.node_id) %>"
         data-modelviewer-format-value="<%= File.extname(@node.name).downcase.delete('.') %>">
      <div class="model-viewer-stage" data-modelviewer-target="canvas"></div>
      <div class="model-viewer-bar">
        <span class="model-viewer-dims" data-modelviewer-target="dims"></span>
        <span class="mv-launch">
          <button type="button" class="btn small" data-action="modelviewer#load">View in 3D</button>
        </span>
        <span class="mv-actions">
          <button type="button" class="btn small ghost" data-action="modelviewer#reset">Reset view</button>
          <button type="button" class="btn small ghost" data-action="modelviewer#fullscreen">Fullscreen</button>
          <button type="button" class="btn small ghost" data-action="modelviewer#showPoster">✕ Image</button>
        </span>
      </div>
      <div class="model-viewer-fallback" data-modelviewer-target="fallback">
        <% if @thumbnail&.status == "ready" && @thumbnail.asset.attached? %>
          <img src="<%= url_for(@thumbnail.asset) %>" alt="Preview of <%= @node.name %>" class="preview-image">
        <% end %>
        <p class="muted">Click <strong>View in 3D</strong> to load an interactive preview, or download the file.</p>
        <%= link_to "Download #{@node.name}", blob_file_path(@node.node_id, download: 1), class: "btn" %>
      </div>
    </div>
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/integration/web/files_flow_test.rb -n "/3D viewer button-gated/"
```
Expected: PASS.

- [ ] **Step 5: Run the whole file-flow suite (no regressions)**

```bash
bin/rails test test/integration/web/files_flow_test.rb
```
Expected: all green (the STEP test at ~line 240 still asserts `.model-viewer` count 0 for STEP; unaffected).

- [ ] **Step 6: Commit**

```bash
git add app/views/files/show.html.erb test/integration/web/files_flow_test.rb
git commit -m "feat(3d-view): button-gate the file-detail 3D viewer (no auto-load)"
```

---

## Task 4: Model page — 3D control bar with file switcher (TDD)

**Files:**
- Test: `test/integration/web/models_flow_test.rb` (add three tests)
- Modify: `app/controllers/models_controller.rb` (`show` + a private constant)
- Create: `app/views/models/_hero_poster.html.erb`
- Modify: `app/views/models/show.html.erb` (the `.model-hero` block, ~lines 28-40)

- [ ] **Step 1: Write the failing tests**

In `test/integration/web/models_flow_test.rb`, add these three tests inside the `ModelsFlowTest` class (e.g. after the existing `"show renders … the file tree"` test):

```ruby
    test "show renders a 3D switcher over STL/3MF/OBJ only, excluding STEP" do
      user = sign_in
      m = user.maker_models.create!(title: "Multi")
      folder = m.ensure_library_folder!(user)
      { "body.stl" => "b1", "lid.3mf" => "l1", "clip.obj" => "c1", "cad.step" => "s1" }.each_with_index do |(name, nid), i|
        user.nodes.create!(node_id: nid, name:, kind: "file", parent_node_id: folder.node_id)
        m.file_attachments.create!(user:, node_id: nid, role: Maker::FileAttachment.role_for(name), position: i)
      end

      get model_path(m)
      assert_response :success
      assert_select ".model-hero.model-viewer[data-modelviewer-lazy-value=?]", "true"
      assert_select "select.model-viewer-source option", count: 3        # stl + 3mf + obj, NOT step
      assert_select "select.model-viewer-source option[data-url=?][data-format=?]", blob_file_path("b1"), "stl"
      assert_select "select.model-viewer-source option[data-format=?]", "3mf"
      assert_select "select.model-viewer-source option[data-format=?]", "obj"
      assert_select "select.model-viewer-source option", text: "cad.step", count: 0
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
    end

    test "show renders the 3D button without a switcher for a single 3D file" do
      user = sign_in
      m = user.maker_models.create!(title: "Solo")
      folder = m.ensure_library_folder!(user)
      user.nodes.create!(node_id: "solo1", name: "body.stl", kind: "file", parent_node_id: folder.node_id)
      m.file_attachments.create!(user:, node_id: "solo1", role: "model")

      get model_path(m)
      assert_response :success
      assert_select ".model-hero.model-viewer[data-modelviewer-url-value=?]", blob_file_path("solo1")
      assert_select ".model-hero.model-viewer[data-modelviewer-format-value=?]", "stl"
      assert_select "select.model-viewer-source", count: 0
      assert_select ".mv-launch [data-action~=?]", "modelviewer#load"
    end

    test "show renders the plain hero with no 3D controls when no viewable 3D files" do
      user = sign_in
      m = user.maker_models.create!(title: "Flat")
      folder = m.ensure_library_folder!(user)
      user.nodes.create!(node_id: "img1", name: "cover.png", kind: "file", parent_node_id: folder.node_id)
      m.file_attachments.create!(user:, node_id: "img1", role: "image")

      get model_path(m)
      assert_response :success
      assert_select ".model-hero"
      assert_select ".model-hero.model-viewer", count: 0
      assert_select "[data-action~=?]", "modelviewer#load", count: 0
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/integration/web/models_flow_test.rb -n "/3D switcher|single 3D file|no 3D controls/"
```
Expected: the first two FAIL (no `.model-hero.model-viewer` / `select.model-viewer-source` yet); the third likely passes already (no 3D controls exist). All three must pass by Step 6.

- [ ] **Step 3: Compute `@viewable_3d` in the controller**

In `app/controllers/models_controller.rb`, add a private constant near the top of the class body:

```ruby
  # Formats modelviewer_controller.js can parse client-side (STL/3MF/OBJ). STEP/IGES are role
  # "model" too but can't be rendered in-browser, so they're excluded from the 3D switcher.
  VIEWABLE_3D_EXTS = %w[stl 3mf obj].freeze
  private_constant :VIEWABLE_3D_EXTS
```

Then, inside `def show`, after the `@cover_att = …` line, add:

```ruby
    # The model's browser-viewable 3D files, in position order, for the hero's "View in 3D"
    # switcher. Filter by extension (role "model" also covers STEP/IGES, which the viewer can't
    # render). Default selection = the cover file if it's viewable, else the first one.
    @viewable_3d = @attachments.filter_map do |a|
      node = @nodes[a.node_id]
      next unless node
      ext = File.extname(node.name).downcase.delete(".")
      next unless VIEWABLE_3D_EXTS.include?(ext)
      { node_id: a.node_id, name: node.name, format: ext }
    end
    @viewable_3d_default = @viewable_3d.find { |f| f[:node_id] == @model.cover_node_id } || @viewable_3d.first
```

- [ ] **Step 4: Extract the hero poster into a partial**

Create `app/views/models/_hero_poster.html.erb` with the current hero content (image cover / thumbnail / placeholder):

```erb
<%# The static hero content: an image cover, else a server-rendered thumbnail of the cover file,
    else the empty placeholder. Reused as the resting poster behind the 3D viewer. Reads the
    @cover_att / @model / @covers ivars set by ModelsController#show. %>
<% if @cover_att&.role == "image" %>
  <%= image_tag blob_file_path(@model.cover_node_id), class: "model-hero-img", alt: @model.title %>
<% elsif @model.cover_node_id %>
  <span class="thumb file-cell model-hero-thumb"
        data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>"
        data-thumbs-target="cell" data-node-id="<%= @model.cover_node_id %>" data-ext="">
    <%= render "files/thumb", thumb: @covers.thumb(@model.cover_node_id), ext_label: "" %>
  </span>
<% else %>
  <span class="model-hero-empty" aria-hidden="true">🧊</span>
<% end %>
```

- [ ] **Step 5: Rewrite the hero block in `show.html.erb`**

In `app/views/models/show.html.erb`, replace the whole `<div class="model-hero"> … </div>` block (~lines 28-40) with:

```erb
    <% if @viewable_3d.any? %>
      <%# The hero doubles as the 3D viewer: click "View in 3D" to swap the poster for the live
          canvas in place; a dropdown switches between the model's 3D files. `lazy` means nothing
          is fetched until the click. When there's a single file, no dropdown — the url/format
          are set on the element so load() uses them directly. %>
      <div class="model-hero model-viewer"
           data-controller="modelviewer"
           data-modelviewer-lazy-value="true"
           <% if @viewable_3d.one? %>
           data-modelviewer-url-value="<%= blob_file_path(@viewable_3d.first[:node_id]) %>"
           data-modelviewer-format-value="<%= @viewable_3d.first[:format] %>"
           <% end %>>
        <div class="model-viewer-stage" data-modelviewer-target="canvas"></div>
        <div class="model-viewer-bar">
          <% if @viewable_3d.many? %>
            <select class="model-viewer-source" data-modelviewer-target="source"
                    data-action="change->modelviewer#selectSource" aria-label="Choose a 3D file">
              <% @viewable_3d.each do |f| %>
                <option value="<%= f[:node_id] %>"
                        data-url="<%= blob_file_path(f[:node_id]) %>"
                        data-format="<%= f[:format] %>"
                        <%= "selected" if f[:node_id] == @viewable_3d_default[:node_id] %>><%= f[:name] %></option>
              <% end %>
            </select>
          <% end %>
          <span class="model-viewer-dims" data-modelviewer-target="dims"></span>
          <span class="mv-launch">
            <button type="button" class="btn small" data-action="modelviewer#load">View in 3D</button>
          </span>
          <span class="mv-actions">
            <button type="button" class="btn small ghost" data-action="modelviewer#reset">Reset view</button>
            <button type="button" class="btn small ghost" data-action="modelviewer#fullscreen">Fullscreen</button>
            <button type="button" class="btn small ghost" data-action="modelviewer#showPoster">✕ Image</button>
          </span>
        </div>
        <div class="model-viewer-fallback" data-modelviewer-target="fallback">
          <%= render "hero_poster" %>
        </div>
      </div>
    <% else %>
      <div class="model-hero">
        <%= render "hero_poster" %>
      </div>
    <% end %>
```

- [ ] **Step 6: Run the model tests to verify they pass**

```bash
bin/rails test test/integration/web/models_flow_test.rb
```
Expected: all green, including the three new tests and the existing hero/file-tree tests.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/models_controller.rb app/views/models/_hero_poster.html.erb app/views/models/show.html.erb test/integration/web/models_flow_test.rb
git commit -m "feat(3d-view): model page hero gets a View-in-3D button + file switcher"
```

---

## Task 5: End-to-end verification (manual browser + full suite on all three backends)

**Files:** none (verification only).

- [ ] **Step 1: Full test suite (default chunk backend)**

```bash
bin/rails test
```
Expected: green.

- [ ] **Step 2: Share backend leg**

```bash
LIBRARY_BACKEND=share bin/rails test test/integration/web/models_flow_test.rb test/integration/web/files_flow_test.rb
```
Expected: green (matches the repo's existing CI legs; the feature only reads via `blob_file_path`, which is backend-agnostic).

- [ ] **Step 3: S3 backend leg**

```bash
LIBRARY_BACKEND=s3 bin/rails test test/integration/web/models_flow_test.rb test/integration/web/files_flow_test.rb
```
Expected: green.

- [ ] **Step 4: Manual browser check — model page**

Start the app (`bin/rails server -p 3001`), sign in, and open a model that has **two or more** STL/3MF/OBJ files (import one via `/models/new`, or attach files to an existing model). Confirm:
- Resting: the static cover hero shows, with a **dropdown** + **View in 3D** button beneath it; no canvas, and the network tab shows **no** model-byte fetch and **no** `three` module download yet.
- Click **View in 3D** → the hero swaps in place for the rotatable 3D model of the selected file; Three.js + the bytes load only now.
- Change the **dropdown** → the viewer swaps to the other file live.
- Click **✕ Image** → returns to the cover hero (and the render loop stops).
- A model with exactly **one** 3D file shows the button but **no** dropdown; a model with **no** 3D files shows the plain hero and **no** button.

- [ ] **Step 5: Manual browser check — file detail page**

Open an STL/3MF/OBJ file's detail page (`/files/:id`). Confirm:
- It does **not** auto-load: the thumbnail poster + **View in 3D** button show, and no bytes/Three.js are fetched until the click.
- Click **View in 3D** → the interactive viewer loads; **✕ Image** returns to the poster.
- Open a **STEP** file's detail page → static thumbnail only, **no** 3D button (unchanged).

- [ ] **Step 6: Degradation spot-check**

In the model or file viewer, confirm that if boot fails the poster stays (e.g. temporarily point `data-modelviewer-url-value` at a 404, or test on a browser tab with WebGL disabled) — the `--ready` class is never added and the poster remains visible. (Optional but recommended; this is the graceful-degradation contract.)

- [ ] **Step 7: Final commit (if any verification-driven tweaks were needed)**

```bash
git add -A && git commit -m "test(3d-view): verify across backends + manual browser passes"
```
(If nothing changed, skip.)

---

## Self-review notes

- **Spec coverage:** model-page button + in-place swap (Task 4), file-switcher dropdown with default selection (Task 4 controller + view), file-page button-gating / "don't send every time" (Tasks 1+3), STL/3MF/OBJ-only with STEP/IGES excluded (Task 4 filter + assertion; Task 3 STEP test unchanged), single/zero-file cases (Task 4 tests), graceful degradation preserved (Task 1 `load()` catch + Task 5 Step 6), backend-agnostic (Task 5 Steps 2-3). All covered.
- **Type/name consistency:** the controller members used by the views — `lazy` value, `source` target, actions `load` / `selectSource` / `showPoster` / `reset` / `fullscreen`, and the CSS classes `model-viewer-source` / `mv-launch` / `mv-actions` — are defined in Task 1/Task 2 and consumed with the same names in Tasks 3-4. `@viewable_3d` items are `{ node_id:, name:, format: }` throughout.
- **No placeholders:** every code and command step is complete.
