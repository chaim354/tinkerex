# Interactive 3D model viewer (STL / 3MF / OBJ) — design

**Date:** 2026-07-22
**Status:** approved, ready for implementation-plan

## 1. Goal

Give the web UI an **interactive** 3D viewer (rotate / zoom / pan) for the mesh
formats a 3D-print library is mostly made of — `.stl`, `.3mf`, `.obj` — rendered
**client-side in the browser**, instantly, with no server conversion job. CAD source
formats the browser can't parse (`.step/.stp/.iges/.igs`) and the other thumbnailable
types (`.dxf/.lbrn2/…`) keep their existing **static server-rendered PNG thumbnail**.

This is a fundamentally different capability from the existing thumbnails: those are
static images produced by a background job; this is a live, manipulable WebGL scene.

## 2. Confirmed decisions

- **Client-side, instant** (not server-side GLB conversion). The browser fetches the
  raw model bytes and parses them with Three.js format loaders. Chosen because the
  library is Printables-sourced (STL/3MF dominate), it needs no async job, no F3D
  dependency, and gives higher fidelity (original mesh).
- **Placement = every 3D file, via the standalone file preview page**
  (`app/views/files/show.html.erb`, route `/files/:id`). This page is *already* the
  link target from the model file tree (`app/views/models/_file_tree.html.erb`) and the
  file browser, so "every 3D file" is covered with **no changes to the file tree and no
  changes to the model detail hero** (the model hero stays a static cover image).
- **File-tree interaction = just link to the page** (current behavior). Clicking a 3D
  file navigates to `/files/:id`, which now hosts the viewer. No modal, no inline
  expand.
- **Controls:** baseline orbit-rotate / zoom / pan / **reset view**, plus **dimensions
  readout** (bounding-box X×Y×Z) and **fullscreen**. No auto-rotate, no wireframe.
- **Units:** STL and OBJ are unitless → assume **millimeters** (the 3D-print
  convention; Printables files are mm). 3MF carries an explicit unit, which `3MFLoader`
  applies.
- **CORS:** where the byte endpoint redirects cross-origin (s3 backend always; small
  single-chunk files on a chunk-over-S3 store), the viewer's `fetch()` needs the bucket
  to allow the app origin. This is a **one-time bucket CORS rule** (documented, JSON
  provided). Until it is set, those files **degrade to the static thumbnail** — nothing
  breaks. Rails is not put in the byte path (honors CLAUDE.md §15).

## 3. Architecture

### 3.1 New Stimulus controller — `app/javascript/controllers/modelviewer_controller.js`

Mirrors the existing `textpreview_controller.js` fetch pattern.

- `static values = { url: String, format: String }` — `url` is `blob_file_path(node_id)`;
  `format` is `"stl" | "3mf" | "obj"`.
- `static targets = [ "canvas", "dims", "fallback" ]` (or equivalent).
- `connect()`:
  1. **Dynamic** `import("three")` and the needed addon(s). Dynamic (not top-level)
     so the ~600 KB Three.js payload loads **only on pages that contain a 3D file**,
     not site-wide (the Stimulus loader eager-imports every controller *module* at
     startup, so a top-level `import` would pull Three on every page).
  2. Feature/guard checks: if WebGL is unavailable → leave fallback, stop.
  3. Build scene: `PerspectiveCamera`, `WebGLRenderer` (sized to the container),
     hemisphere + directional lights, `OrbitControls` (damped).
  4. `fetch(this.urlValue, { credentials: "same-origin" })` → `arrayBuffer`.
  5. Parse per `format`:
     - `stl` → `STLLoader().parse(buf)` → `BufferGeometry` → wrap in `Mesh` with a
       neutral `MeshStandardMaterial`.
     - `3mf` → `ThreeMFLoader().parse(buf)` → `Group` (respects embedded materials).
     - `obj` → `OBJLoader().parse(textDecode(buf))` → `Group` (geometry only; no `.mtl`).
  6. Normalize: compute bounding box, center the model at the origin, frame the camera
     to fit, set `OrbitControls.target` to the center.
  7. Populate the **dimensions readout** from the bounding-box size (X×Y×Z, mm).
  8. Start the render loop (`requestAnimationFrame`); on `ResizeObserver` resize the
     renderer/camera.
- `disconnect()`: stop the RAF loop, dispose geometry/material/renderer, disconnect
  observers (Turbo navigations must not leak WebGL contexts).
- Buttons wired via Stimulus actions: **reset view** (restore initial camera/target),
  **fullscreen** (`requestFullscreen()` on the container; re-layout on change).
- **Graceful degradation:** any failure in steps 1–6 (import error, WebGL missing,
  `fetch` rejected/CORS, parse throw) → catch, keep the static thumbnail fallback
  visible, log a console warning. Never show a broken/black canvas.

### 3.2 Controller / view changes

- `FilesController#preview_kind` (`app/controllers/files_controller.rb`): add a
  `:model3d` case returning for `%w[stl 3mf obj]` **before** the `:thumbnail` branch.
  Everything else is unchanged (step/stp/iges/igs/dxf/lbrn2/… still `:thumbnail`).
- `FilesController#show`: continue to load `@thumbnail` for `:model3d` as well as
  `:thumbnail`, so the fallback poster is available. (Single guard change: wherever
  the thumbnail is loaded/gated on `@kind == :thumbnail`, include `:model3d`.)
- `app/views/files/show.html.erb`: add a `:model3d` branch in the `.preview` block:
  ```erb
  <% elsif @kind == :model3d %>
    <div class="model-viewer"
         data-controller="modelviewer"
         data-modelviewer-url-value="<%= blob_file_path(@node.node_id) %>"
         data-modelviewer-format-value="<%= File.extname(@node.name).downcase.delete('.') %>">
      <div class="model-viewer-canvas" data-modelviewer-target="canvas"></div>
      <div class="model-viewer-dims" data-modelviewer-target="dims"></div>
      <div class="model-viewer-controls">…reset / fullscreen buttons…</div>
      <div class="model-viewer-fallback" data-modelviewer-target="fallback">
        <%# static thumbnail poster shown until/unless the viewer boots %>
        <% if @thumbnail&.status == "ready" && @thumbnail.asset.attached? %>
          <img src="<%= url_for(@thumbnail.asset) %>" alt="Preview of <%= @node.name %>">
        <% end %>
        <%= link_to "Download #{@node.name}", blob_file_path(@node.node_id, download: 1), class: "btn" %>
      </div>
    </div>
  ```
  The `:thumbnail` branch and all others stay exactly as-is.
- CSS: a `.model-viewer` block in the existing stylesheet (fixed-aspect container,
  canvas fill, dims/controls overlay, fullscreen sizing). Follow the existing
  `.preview` / `.preview-image` conventions.

### 3.3 Vendored libraries (importmap, committed) — the JSZip pattern

Vendor into `vendor/javascript/` and pin in `config/importmap.rb`, exactly like the
existing JSZip precedent. All bytes committed to git; nothing fetched at runtime or in
CI (satisfies the self-hosted/offline-CI constraint).

- `three` (core ES module build).
- `three/addons/loaders/STLLoader.js`
- `three/addons/loaders/3MFLoader.js` (imports `fflate` for the zip container).
- `three/addons/loaders/OBJLoader.js`
- `three/addons/controls/OrbitControls.js`
- `fflate` (dependency of `3MFLoader`).

**Gotcha (documented in `config/importmap.rb`'s JSZip war-story):** Three addons use a
bare `three` specifier and relative sub-imports. Follow the method: `bin/importmap pin`
each, inspect the vendored files for dangling relative-import chunks, vendor those too,
repoint specifiers, and verify no unvendored import remains. Pin the addons under
stable bare specifiers (e.g. `three/addons/loaders/STLLoader.js`) so the loader files'
internal `import ... from 'three'` resolves to the vendored core.

**Licensing:** Three.js is **MIT**; fflate is **MIT** — both permissive (CLAUDE.md §9 ✅).

## 4. Data flow & byte delivery

1. Page renders the `modelviewer` container with `url = blob_file_path(node_id)`
   (same-origin, carries the Devise session cookie).
2. Controller `fetch`es that URL.
3. `FilesController#blob` → `FileLayer.current.download(...)` → a `Delivery`:
   - **share** → `SendFile` (same-origin) → works.
   - **chunk**, multi-chunk file → `Stream` (same-origin) → works.
   - **chunk**, single-chunk on S3 store → `Redirect` (cross-origin presigned).
   - **s3** → `Redirect` (cross-origin presigned).
4. For cross-origin redirects the browser enforces CORS on the **final** response. The
   bucket must return `Access-Control-Allow-Origin: <app origin>` for `GET`. Rails
   cannot set this (bytes bypass Rails — §15).

**Deployment note (to document in `docs/`):** for s3 / SeaweedFS deployments, add a
bucket CORS rule allowing `GET` from the app origin, e.g.:
```json
[{ "AllowedOrigins": ["https://<app-host>"], "AllowedMethods": ["GET"],
   "AllowedHeaders": ["*"], "MaxAgeSeconds": 3600 }]
```
Without it, cross-origin files degrade to the static thumbnail (no breakage). The
**share** backend and multi-chunk files on the **chunk** backend need nothing.

## 5. Error handling & degradation

The static server-rendered thumbnail remains the safety net in every failure mode:

| Failure | Behavior |
|---|---|
| WebGL unavailable | keep thumbnail poster + download link |
| `import("three")` fails | keep thumbnail poster + download link |
| `fetch` fails / cross-origin CORS blocked | keep thumbnail poster + download link |
| loader `parse` throws (corrupt/odd file) | keep thumbnail poster + download link |
| no thumbnail exists (e.g. OBJ w/o F3D) | show download link (no poster) |

## 6. Testing

- **Rails tests (no browser):**
  - `preview_kind` returns `:model3d` for `stl/3mf/obj` and `:thumbnail` for
    `step/stp/iges/igs/dxf/lbrn2`.
  - `files/show` for a 3D file renders the `data-controller="modelviewer"` container
    with the correct `data-modelviewer-url-value` and `data-modelviewer-format-value`,
    and includes the fallback thumbnail poster.
  - `files/show` for a `step` file still renders the `:thumbnail` `<img>` (unchanged).
  - Runs green on all three backend legs (`bin/rails test`, `LIBRARY_BACKEND=share`,
    `LIBRARY_BACKEND=s3`) — consistent with the repo's existing CI matrix.
- **No JS unit-test harness** exists (no Node/bundler). The viewer interaction
  (rotate/zoom/pan/reset, dimensions, fullscreen, graceful fallback) is verified
  **manually in the browser** on at least the chunk and share backends — consistent
  with how the other client-side features here were validated.

## 7. Out of scope (YAGNI)

Interactive model-page hero; in-tree modal/inline viewer; auto-rotate; wireframe
toggle; OBJ `.mtl` materials; server-side GLB pipeline for STEP/IGES (they keep static
thumbnails); measurement tools; section/clipping planes.

## 8. Files touched

- **New:** `app/javascript/controllers/modelviewer_controller.js`
- **New (vendored, committed):** `vendor/javascript/three*.js`, addon files, `fflate.js`
- **Edit:** `config/importmap.rb` (pins)
- **Edit:** `app/controllers/files_controller.rb` (`preview_kind` + `@thumbnail` gate)
- **Edit:** `app/views/files/show.html.erb` (`:model3d` branch)
- **Edit:** stylesheet (`.model-viewer` styles)
- **New/Edit:** `docs/` deployment note (bucket CORS)
- **New:** controller/view tests
