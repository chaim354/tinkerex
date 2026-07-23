# Interactive 3D Model Viewer (STL/3MF/OBJ) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interactive, client-side 3D viewer (rotate/zoom/pan) for STL/3MF/OBJ on the file preview page, with the existing static thumbnail as a graceful fallback.

**Architecture:** A new `:model3d` preview kind routes STL/3MF/OBJ to a new branch in `app/views/files/show.html.erb` that renders a `modelviewer` Stimulus controller container. The controller dynamically imports Three.js (so it ships only on pages with a 3D file), `fetch`es the raw bytes from the same-origin blob endpoint, parses them with the format's Three.js loader, and renders a WebGL scene. Any failure keeps the server-rendered thumbnail poster visible. STEP/IGES/DXF/etc. are unchanged (still `:thumbnail`).

**Tech Stack:** Rails 8, Hotwire/Stimulus, importmap-rails + Propshaft (no Node/bundler; libraries vendored into `vendor/javascript/` and committed — the existing JSZip pattern), Three.js (MIT) + STL/3MF/OBJ loaders + OrbitControls, fflate (MIT, 3MF's unzip dep).

**Spec:** `docs/superpowers/specs/2026-07-22-3d-model-viewer-design.md`

---

## Context the engineer needs

- **Preview kind flows through one method.** `FilesController#preview_kind` (`app/controllers/files_controller.rb:493`) maps a filename to `:image | :pdf | :text | :thumbnail | :other`. `#show` sets `@kind` from it (line 192). `app/views/files/show.html.erb` (the `.preview` block, lines 49–75) branches on `@kind`. STL/3MF/OBJ currently return `:thumbnail` because `Maker::Previews::Registry.for(ext)` has renderers for them.
- **`@thumbnail` is loaded unconditionally** when the file has content (`files_controller.rb:194`, keyed `kind: "thumbnail"`) — NOT gated on `@kind`. So the fallback poster is already available for a `:model3d` file. **No `#show` change is needed beyond `preview_kind`.**
- **The blob endpoint** `blob_file_path(node_id)` (`GET /files/:id/blob`) serves the raw bytes, session-authed, same-origin. `Content-Disposition: attachment` does NOT block `fetch()`. On s3 (and small single-chunk files on chunk-over-S3) it 302s to a cross-origin presigned URL — that leg needs bucket CORS, else the fetch rejects and we fall back.
- **Vendoring pattern + gotchas** are documented in `config/importmap.rb:9–27` (the JSZip war-story): `bin/importmap pin` downloads into `vendor/javascript/` (committed); vendored files can carry dangling relative imports to internal chunks that must be fetched and repointed to a bare pinned specifier. Three.js addons import a bare `three` specifier + relative sub-imports and will need the same inspect-and-repoint treatment.
- **No JS test harness exists** (no Node/package.json). The Stimulus controller is verified by manual browser smoke; the Rails-side wiring (kind → container HTML/data-attrs) is covered by integration tests in `test/integration/web/files_flow_test.rb`.
- **Test command:** `bin/rails test test/integration/web/files_flow_test.rb`. Full suite: `bin/rails test`. The three-backend legs: `LIBRARY_BACKEND=share bin/rails test` and `LIBRARY_BACKEND=s3 bin/rails test` (this suite is `pin_file_layer_backend("chunk")`, so its own assertions always run chunk — the other legs guard the rest of the suite).

## File structure

- **Modify** `app/controllers/files_controller.rb` — `preview_kind` gains a `:model3d` case (one line).
- **Modify** `app/views/files/show.html.erb` — a `:model3d` branch in the `.preview` block.
- **Modify** `app/assets/stylesheets/application.css` — `.model-viewer*` styles (next to the existing `.preview*` rules).
- **Modify** `test/integration/web/files_flow_test.rb` — new `:model3d` assertions; repair the one existing test that leaned on STL being `:thumbnail`.
- **Modify** `config/importmap.rb` — pins for `three`, the addons, and `fflate`.
- **Create (vendored, committed)** `vendor/javascript/three.module.js` + `STLLoader.js` + `3MFLoader.js` + `OBJLoader.js` + `OrbitControls.js` + `fflate.js` (exact filenames may vary; pins repoint specifiers).
- **Create** `app/javascript/controllers/modelviewer_controller.js` — the viewer.
- **Modify** `docs/DEPLOY.md` (or nearest deploy doc) — bucket CORS note.

---

## Task 1: Route STL/3MF/OBJ to a `:model3d` kind + render the viewer container

**Files:**
- Modify: `app/controllers/files_controller.rb:493-505` (`preview_kind`)
- Modify: `app/views/files/show.html.erb:49-75` (the `.preview` block)
- Modify: `app/assets/stylesheets/application.css` (after the `.preview*` block, ~line 88)
- Test: `test/integration/web/files_flow_test.rb`

- [ ] **Step 1: Write the failing test**

Add these tests inside `class FilesFlowTest` in `test/integration/web/files_flow_test.rb` (e.g. after the existing `"the PDF detail page embeds the PDF viewer…"` test):

```ruby
test "an STL detail page renders the interactive 3D viewer container" do
  sign_in
  node_id = upload("bracket.stl", "solid bracket\nendsolid\n".b)

  get file_path(node_id)
  assert_response :success
  assert_select ".model-viewer[data-controller=?]", "modelviewer"
  assert_select ".model-viewer[data-modelviewer-url-value=?]", blob_file_path(node_id)
  assert_select ".model-viewer[data-modelviewer-format-value=?]", "stl"
  # The reset/fullscreen controls the user asked for are wired.
  assert_select "[data-action~=?]", "modelviewer#reset"
  assert_select "[data-action~=?]", "modelviewer#fullscreen"
end

test "3MF and OBJ also render the 3D viewer, with the right format value" do
  sign_in
  { "part.3mf" => "3mf", "widget.obj" => "obj" }.each do |name, fmt|
    node_id = upload(name, "data".b)
    get file_path(node_id)
    assert_response :success
    assert_select ".model-viewer[data-modelviewer-format-value=?]", fmt
  end
end

test "a STEP file keeps the static thumbnail preview (not the 3D viewer)" do
  user = sign_in
  node_id = upload("cad.step", "ISO-10303-21;".b)
  token = FileLayer.current.stat(user, node_id:).content_token
  preview = user.maker_previews.find_by!(node_id:, version_id: token, kind: "thumbnail")
  preview.update!(status: "ready")
  preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")

  get file_path(node_id)
  assert_response :success
  assert_select "img.preview-image"
  assert_select ".model-viewer", count: 0
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/integration/web/files_flow_test.rb -n "/3D viewer|3MF and OBJ|STEP file keeps/"`
Expected: FAIL — no `.model-viewer` element is rendered yet (STL currently renders the `:thumbnail` branch).

- [ ] **Step 3: Add the `:model3d` case to `preview_kind`**

In `app/controllers/files_controller.rb`, in `preview_kind` (line 493), add the STL/3MF/OBJ case immediately **before** the `:thumbnail` line (line 503):

```ruby
  def preview_kind(name)
    ext = File.extname(name).downcase.delete(".")
    return :image if %w[png jpg jpeg gif webp svg bmp ico].include?(ext)
    # PDF before the :thumbnail branch: the detail view EMBEDS the whole PDF for the browser's own
    # viewer (a full, scrollable preview), while pdf is ALSO in Registry for a page-1 grid thumbnail.
    return :pdf   if ext == "pdf"
    return :text  if %w[txt md markdown csv json xml yml yaml log rb js ts py rs go
                        c h cpp html css toml ini cfg conf sh gcode].include?(ext)
    # Mesh formats the browser can parse itself -> the interactive client-side 3D viewer
    # (modelviewer_controller.js), which supersedes the static thumbnail on the detail page. The
    # thumbnail is still generated (Registry has these) and is the viewer's fallback poster.
    return :model3d if %w[stl 3mf obj].include?(ext)
    # A file we can render a server-side thumbnail for (dxf, lbrn2, step, stp, iges, igs, ...) but
    # that the browser can't display raw. The :thumbnail branch in show.html.erb reads @thumbnail.
    return :thumbnail if Maker::Previews::Registry.for(ext)
    :other
  end
```

- [ ] **Step 4: Add the `:model3d` branch to the view**

In `app/views/files/show.html.erb`, add a branch in the `.preview` block, immediately **before** the `<% elsif @kind == :thumbnail && @thumbnail&.status == "ready" ... %>` line (line 62):

```erb
  <% elsif @kind == :model3d %>
    <%# Interactive client-side 3D viewer (Three.js), see modelviewer_controller.js. The nested
        fallback (static thumbnail poster + download link) shows until the viewer boots, and stays
        if it can't (no WebGL, a cross-origin fetch without bucket CORS, or a corrupt file). %>
    <div class="model-viewer"
         data-controller="modelviewer"
         data-modelviewer-url-value="<%= blob_file_path(@node.node_id) %>"
         data-modelviewer-format-value="<%= File.extname(@node.name).downcase.delete('.') %>">
      <div class="model-viewer-stage" data-modelviewer-target="canvas"></div>
      <div class="model-viewer-bar">
        <span class="model-viewer-dims" data-modelviewer-target="dims"></span>
        <span class="model-viewer-actions">
          <button type="button" class="btn small ghost" data-action="modelviewer#reset">Reset view</button>
          <button type="button" class="btn small ghost" data-action="modelviewer#fullscreen">Fullscreen</button>
        </span>
      </div>
      <div class="model-viewer-fallback" data-modelviewer-target="fallback">
        <% if @thumbnail&.status == "ready" && @thumbnail.asset.attached? %>
          <img src="<%= url_for(@thumbnail.asset) %>" alt="Preview of <%= @node.name %>" class="preview-image">
        <% end %>
        <p class="muted">Download the file to view it in 3D.</p>
        <%= link_to "Download #{@node.name}", blob_file_path(@node.node_id, download: 1), class: "btn" %>
      </div>
    </div>
```

- [ ] **Step 5: Add the viewer styles**

In `app/assets/stylesheets/application.css`, after the `.preview-fallback` rule (line 88), add:

```css
/* --- Interactive 3D viewer (modelviewer_controller.js) — STL/3MF/OBJ --- */
.model-viewer { position: relative; }
.model-viewer-stage {
  width: 100%; height: 60vh; min-height: 320px; border-radius: 6px;
  background: var(--soft); display: none; touch-action: none;
}
.model-viewer-stage canvas { display: block; border-radius: 6px; }
.model-viewer-bar { display: none; align-items: center; justify-content: space-between; gap: 12px; margin-top: 8px; }
.model-viewer-dims { color: var(--muted); font-variant-numeric: tabular-nums; }
.model-viewer-fallback { text-align: center; padding: 24px; }
/* The controller adds --ready on a successful render: reveal the canvas + bar, hide the poster. */
.model-viewer--ready .model-viewer-stage { display: block; }
.model-viewer--ready .model-viewer-bar { display: flex; }
.model-viewer--ready .model-viewer-fallback { display: none; }
.model-viewer:fullscreen { background: var(--soft); padding: 12px; }
.model-viewer:fullscreen .model-viewer-stage { height: calc(100vh - 64px); }
```

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `bin/rails test test/integration/web/files_flow_test.rb -n "/3D viewer|3MF and OBJ|STEP file keeps/"`
Expected: PASS (3 tests).

- [ ] **Step 7: Repair the existing test that relied on STL being `:thumbnail`**

`test/integration/web/files_flow_test.rb:318` (`"unknown type falls back to a download link"`) uploads `model.stl` and asserts `.preview-fallback`. STL is now `:model3d`, so this must switch to a genuinely non-renderable type (its stated intent). Change the fixture:

```ruby
    test "unknown type falls back to a download link" do
      sign_in
      node_id = upload("model.sldprt", "binary cad".b)  # not renderable -> :other -> download fallback
      get file_path(node_id)
      assert_response :success
      assert_select ".preview-fallback"
    end
```

- [ ] **Step 8: Run the whole file suite to verify nothing else regressed**

Run: `bin/rails test test/integration/web/files_flow_test.rb`
Expected: PASS (all tests green — confirms no other STL-based test broke).

- [ ] **Step 9: Commit**

```bash
git add app/controllers/files_controller.rb app/views/files/show.html.erb \
        app/assets/stylesheets/application.css test/integration/web/files_flow_test.rb
git commit -m "feat(models): route STL/3MF/OBJ to an interactive 3D viewer container

New :model3d preview kind + a viewer container on the file detail page, with
the server-rendered thumbnail as the fallback poster. Controller JS + vendored
Three.js follow. STEP/IGES/DXF keep their static thumbnails.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Vendor Three.js + loaders + fflate (importmap, committed)

**Files:**
- Create (vendored): `vendor/javascript/three.module.js`, `STLLoader.js`, `3MFLoader.js`, `OBJLoader.js`, `OrbitControls.js`, `fflate.js` (exact download names may differ; the pins repoint specifiers)
- Modify: `config/importmap.rb`

No automated test — verification is asset resolution (no dangling imports) here, and the browser smoke in Task 4. This mirrors how JSZip was vendored (`config/importmap.rb:9-27`).

- [ ] **Step 1: Pin the core + addons + fflate (downloads into `vendor/javascript/`)**

Run each (network access is one-time on the dev box; the bytes get committed):

```bash
bin/importmap pin three
bin/importmap pin three/examples/jsm/controls/OrbitControls.js
bin/importmap pin three/examples/jsm/loaders/STLLoader.js
bin/importmap pin three/examples/jsm/loaders/OBJLoader.js
bin/importmap pin three/examples/jsm/loaders/3MFLoader.js
bin/importmap pin fflate
```

Expected: new files under `vendor/javascript/` and auto-added `pin` lines in `config/importmap.rb`.

- [ ] **Step 2: Normalize the pins to the specifiers the controller imports**

Edit `config/importmap.rb` so the specifiers are exactly these (rename `to:` targets to the actual vendored filenames from Step 1; keep the JSZip block above untouched). Add a short comment mirroring the JSZip one:

```ruby
# Three.js r0.160+ (MIT) — the interactive 3D viewer (modelviewer_controller.js). Vendored via
# `bin/importmap pin three` + each addon; loaded through a DYNAMIC import in the controller so the
# ~600KB core ships only on pages with a 3D file. Addons import a bare "three" specifier and relative
# sub-imports (same class of dangling-import as JSZip above) — repointed to these bare specifiers.
pin "three", to: "three.module.js"
pin "three/addons/controls/OrbitControls.js", to: "OrbitControls.js"
pin "three/addons/loaders/STLLoader.js", to: "STLLoader.js"
pin "three/addons/loaders/OBJLoader.js", to: "OBJLoader.js"
pin "three/addons/loaders/3MFLoader.js", to: "3MFLoader.js"
pin "fflate" # MIT — 3MFLoader's unzip dependency
```

- [ ] **Step 3: Repoint dangling imports inside the vendored files**

Inspect each vendored addon for imports that don't resolve to a pin above:

```bash
grep -nE "^import|from ['\"]" vendor/javascript/OrbitControls.js vendor/javascript/STLLoader.js \
  vendor/javascript/OBJLoader.js vendor/javascript/3MFLoader.js | grep -vE "from ['\"](three|fflate)['\"]"
```

For every hit (e.g. a relative `../../../build/three.module.js`, a versioned jspm URL, or `3MFLoader.js` importing fflate via a relative `../libs/fflate.module.js`), edit that import line to the bare pinned specifier: three-core imports → `from "three"`; fflate imports → `from "fflate"`. If `bin/importmap pin` left a dangling internal jspm chunk (as it did for JSZip's `buffer.js`), fetch it the same way (`bin/importmap pin <chunk>`) and repoint — but three's addons usually import only `three`/`fflate`, so expect just those two. Re-run the grep until it returns nothing.

- [ ] **Step 4: Verify the importmap resolves and there are no dangling relative imports**

Run:
```bash
bin/importmap json | grep -E "\"three|fflate"
grep -rnE "from ['\"]\.\.?/" vendor/javascript/three.module.js vendor/javascript/OrbitControls.js \
  vendor/javascript/STLLoader.js vendor/javascript/OBJLoader.js vendor/javascript/3MFLoader.js || echo "no dangling relative imports"
```
Expected: the `three`/`three/addons/*`/`fflate` specifiers appear in the importmap JSON; the second grep prints `no dangling relative imports`.

- [ ] **Step 5: Confirm assets are served (boot + fetch one module)**

Run:
```bash
bin/rails runner 'puts Rails.application.assets.load_path.find("three.module.js")&.path'
```
Expected: a non-empty path (Propshaft resolves the vendored core). If nil, the filename in the pin doesn't match the vendored file — fix `to:`.

- [ ] **Step 6: Commit**

```bash
git add config/importmap.rb vendor/javascript/
git commit -m "build(models): vendor Three.js + STL/3MF/OBJ loaders + fflate (importmap)

MIT-licensed, committed to vendor/javascript/ (offline-CI safe), pinned as bare
three/three-addons specifiers. Dynamic-imported by the viewer so the core ships
only on 3D-file pages. Follows the documented JSZip vendoring pattern.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: The `modelviewer` Stimulus controller

**Files:**
- Create: `app/javascript/controllers/modelviewer_controller.js`

No JS unit harness — verified by the browser smoke in Task 4. The controller auto-registers by filename (`eagerLoadControllersFrom`).

- [ ] **Step 1: Write the controller**

Create `app/javascript/controllers/modelviewer_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Interactive 3D viewer for the mesh formats a print library is made of (STL / 3MF / OBJ).
// Parses the raw model bytes CLIENT-SIDE — no server conversion — and renders a manipulable
// WebGL scene. Three.js (~600KB) is pulled via a DYNAMIC import in boot() so it ships only on
// pages that actually contain a 3D file, not site-wide (Stimulus eager-imports controller
// MODULES at startup, so a top-level `import` would load Three everywhere).
//
// Graceful degradation is the contract: any failure (no WebGL, import error, fetch/CORS failure,
// corrupt file) leaves the server-rendered thumbnail poster visible. The `--ready` class, added
// only on a successful first render, is what reveals the canvas and hides that poster.
export default class extends Controller {
  static values = { url: String, format: String }
  static targets = ["canvas", "dims", "fallback"]

  async connect() {
    this.disposed = false
    try {
      await this.boot()
    } catch (e) {
      console.warn("[modelviewer] keeping thumbnail fallback:", e)
    }
  }

  disconnect() {
    this.disposed = true
    if (this.frame) cancelAnimationFrame(this.frame)
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.controls) this.controls.dispose()
    this.scene?.traverse((o) => {
      o.geometry?.dispose?.()
      if (o.material) [].concat(o.material).forEach((m) => m.dispose?.())
    })
    if (this.renderer) {
      this.renderer.dispose()
      this.renderer.domElement?.remove()
    }
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
    if (this.disposed) return
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

- [ ] **Step 2: Sanity-check the file is valid and registers**

Run: `bin/rails runner 'puts Rails.application.assets.load_path.find("controllers/modelviewer_controller.js")&.path'`
Expected: a non-empty path (Propshaft sees the controller; `pin_all_from` will serve it).

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/modelviewer_controller.js
git commit -m "feat(models): modelviewer Stimulus controller (Three.js STL/3MF/OBJ)

Dynamic-imports Three.js + the format loader, fetches the raw bytes from the
blob endpoint, renders an OrbitControls scene with a dimensions readout + reset
+ fullscreen. Any failure keeps the static thumbnail fallback visible.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Browser smoke test (manual) + bucket-CORS deploy note

**Files:**
- Modify: `docs/DEPLOY.md` (bucket CORS note)

- [ ] **Step 1: Boot the app against a byte-serving backend**

The viewer needs real bytes. Use the share backend (same-origin, no CORS to configure) for the smoke:

```bash
LIBRARY_BACKEND=share LIBRARY_PATH=/tmp/maker-smoke bin/rails server -p 3001
```
(Or the running deployment. Create `/tmp/maker-smoke` first if needed.)

- [ ] **Step 2: Verify the viewer in a browser**

Sign in, upload (or open) a `.stl`, a `.3mf`, and a `.obj`, and open each file's detail page (`/files/:id`). Confirm for each:
- The model renders and you can **orbit-rotate, zoom, and pan** it.
- The **dimensions readout** shows `X × Y × Z mm`.
- **Reset view** returns the camera to the framed start.
- **Fullscreen** expands the viewer and the model re-fits.
- Open a `.step` file → still the **static thumbnail** (no viewer).
- Force a failure (e.g. temporarily point `data-modelviewer-url-value` at a 404, or throttle offline) → the **thumbnail poster + download link stay visible**, no broken black canvas, a `[modelviewer]` warning in the console.

Use the in-app Browser tools (mcp__Claude_Browser__*) or a real browser. Record the result in the PR description.

- [ ] **Step 3: Document the bucket CORS requirement**

In `docs/DEPLOY.md`, add a short subsection (near the S3/SeaweedFS storage config):

```markdown
### 3D viewer & bucket CORS (s3 / chunk-over-S3 deployments)

The in-browser 3D viewer (`modelviewer_controller.js`) `fetch`es a model file's raw
bytes from `/files/:id/blob`. On the **s3** backend — and for small single-chunk files
on a **chunk** backend whose store is S3/SeaweedFS — that endpoint 302-redirects to a
cross-origin presigned URL, which the browser will only read if the bucket returns CORS
headers for the app origin. Rails cannot set these (bytes bypass Rails by design, §15).

Add a bucket CORS rule allowing GET from the app origin, e.g.:

    [{ "AllowedOrigins": ["https://<app-host>"], "AllowedMethods": ["GET"],
       "AllowedHeaders": ["*"], "MaxAgeSeconds": 3600 }]

(SeaweedFS: `s3.configure` / the bucket CORS API; R2/S3: the bucket's CORS config.)
Without it, affected files **degrade to the static thumbnail** — nothing breaks. The
**share** backend and multi-chunk files on the chunk backend are same-origin and need
no CORS.
```

- [ ] **Step 4: Commit**

```bash
git add docs/DEPLOY.md
git commit -m "docs(deploy): bucket CORS for the in-browser 3D viewer (s3 backends)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Full regression across all three backends

- [ ] **Step 1: Run the full suite on the default (chunk) backend**

Run: `bin/rails test`
Expected: all green (matches the pre-change baseline count + the 3 new tests).

- [ ] **Step 2: Run the share and s3 legs**

Run:
```bash
LIBRARY_BACKEND=share bin/rails test
LIBRARY_BACKEND=s3 bin/rails test
```
Expected: both green (the viewer change is backend-neutral — same `blob_file_path` route, same HTML). If the s3 leg needs S3 stub env, follow the existing pattern in `test/services/file_layer` / `test_helper` for the s3 test leg.

- [ ] **Step 3: Confirm no dangling assets in production mode**

Run: `RAILS_ENV=production SECRET_KEY_BASE=dummy bin/rails assets:precompile 2>&1 | tail -5`
Expected: precompiles without error (the vendored three/fflate files are picked up by Propshaft). Then `git checkout public/assets 2>/dev/null; rm -rf public/assets` if precompile wrote artifacts you don't want committed.

- [ ] **Step 4: Final commit (if any doc/status updates)**

Update `docs/STATUS.md` and/or `CLAUDE.md` memory notes if this feature warrants a status line (a new user-facing capability: interactive 3D preview). Keep it to one line in the relevant "current state" section.

```bash
git add -A && git commit -m "docs(status): note interactive 3D viewer for STL/3MF/OBJ

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** placement on `/files/:id` (Task 1) ✅; client-side instant STL/3MF/OBJ (Tasks 1,3) ✅; STEP/IGES keep thumbnails (Task 1, verified by the STEP test) ✅; baseline orbit/zoom/pan + reset (Task 3) ✅; dimensions readout (Task 3) ✅; fullscreen (Task 3) ✅; vendored libraries, offline-CI (Task 2) ✅; CORS + graceful fallback (Tasks 3,4) ✅; testing on 3 backends (Task 5) ✅; docs note (Task 4) ✅.
- **No model-page-hero / no in-tree modal** — correctly out of scope (the file tree already links to `/files/:id`, unchanged).
- **Type/name consistency:** the controller's `static targets = ["canvas","dims","fallback"]` match the view's `data-modelviewer-target` values; `data-action` values `modelviewer#reset` / `modelviewer#fullscreen` match the controller methods; the `--ready` class is added by the controller and consumed by the CSS; format values `stl|3mf|obj` match `preview_kind` and the controller's `switch`.
- **The one cross-task risk** is Task 2's vendoring inspect-and-repoint loop (inherently exploratory, like JSZip). Its verification gate (no dangling relative imports + importmap JSON + the Task 4 browser smoke) is what catches a bad pin.
