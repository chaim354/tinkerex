# 3D View Button — Design

**Date:** 2026-07-24
**Status:** Approved (brainstorm), pending implementation plan
**Branch:** `claude/3d-view-button-options-66c249`

## Summary

Make the interactive 3D viewer **opt-in** and give it a **file switcher**.

Today the Three.js viewer (`modelviewer_controller.js`) only appears on the single-file
detail page (`/files/:id`), where it **auto-boots** — fetching and parsing the raw model
bytes the instant the page loads. The model detail page (`/models/:slug`) has no interactive
3D at all; its hero is a static cover image or rendered PNG thumbnail.

This feature:

1. Adds a **"View in 3D" button** to the model page that replaces the static hero, *in place*,
   with the live viewer — plus a **dropdown to switch between a model's 3D files** when it has
   more than one.
2. Makes the file detail page's viewer **button-gated** instead of auto-loading, so heavy model
   bytes (and the ~2 MB Three.js bundle) are fetched only when the user asks for 3D.

## Motivation

- The model page is the natural place to view a print in 3D, but currently forces a drill-down:
  model → file tree → file detail page → viewer. A model with several parts (`body.stl`,
  `lid.stl`, …) has no way to view/switch them from the model page.
- Auto-loading the viewer "sends every time" — every visit to a 3D file's page fetches the full
  model bytes and downloads Three.js, even when the user only wanted the metadata or a thumbnail.
  A button defers all of that until it's wanted.

## Scope

**In scope**

| Surface | Change |
|---|---|
| Model detail page `/models/:slug` | Static hero → control bar (file dropdown + "View in 3D"); click swaps the hero in place for the live viewer; dropdown switches files live; "✕ image" returns to the cover. |
| File detail page `/files/:id` | The `:model3d` preview stops auto-booting; thumbnail poster + "View in 3D" button; viewer boots (and Three.js loads) only on click. |

**Formats:** STL / 3MF / OBJ — the formats the existing client-side viewer can parse. STEP / STP
/ IGES / IGS keep their static server-rendered thumbnail and get **no** 3D button.

**Out of scope (YAGNI)**

- STEP/IGES interactive 3D (would need server-side GLB via F3D — not installed on the deploy box —
  plus a GLTF loader). Possible later follow-up; the dormant `model_glb` scaffolding in
  `Maker::Previews::Mesh` stays dormant.
- Inline 3D in the file browser grid/list (`/files`). Untouched.
- Remembering an "always open in 3D" preference.
- Updating the static hero image to the selected file's thumbnail *before* the viewer is loaded.

## Behavior specification

### Model detail page

- **Zero** viewable (STL/3MF/OBJ) files → page is exactly as today (image cover, thumb cover, or
  🧊 placeholder). No control bar, no button.
- **One** viewable file → poster hero + a control bar with a **View in 3D** button. No dropdown.
- **Two or more** viewable files → poster hero + control bar with a **dropdown** (file names) and
  the **View in 3D** button.
- **Resting state:** the existing hero (cover image / thumbnail / placeholder) is shown as the
  poster; the dropdown (if present) and "View in 3D" are visible.
- **On "View in 3D":** the currently selected file's bytes are fetched and rendered; the poster is
  hidden and the canvas revealed (existing `--ready` mechanism). The control bar now shows the
  dropdown, **Reset**, **Fullscreen**, and **✕ image**.
- **On dropdown change while in 3D:** the current scene is disposed and the newly selected file is
  loaded. (While resting, changing the dropdown only changes what "View in 3D" will load — no
  fetch.)
- **On "✕ image":** the scene is disposed (frees GPU memory, stops the render loop) and the poster
  hero returns.
- **Default selected file:** the model's cover file if it is itself a viewable 3D file, otherwise
  the first viewable file by `position`.

### File detail page

- The `:model3d` branch renders the same viewer element but with `lazy` set. Resting state = the
  existing fallback (server thumbnail poster if ready + a download link) plus a **View in 3D**
  button. Reset/Fullscreen are hidden until the viewer is loaded.
- On "View in 3D": identical boot to today, just deferred to the click. Single file, so no dropdown.

### Degradation (unchanged contract)

Any failure — no WebGL, a cross-origin presigned fetch without bucket CORS, a corrupt file — leaves
the poster visible and logs a warning, exactly as today. The `--ready` class is added only on a
successful first render.

## Architecture

### One reused viewer controller (`app/javascript/controllers/modelviewer_controller.js`)

The viewer already owns the canvas, Three.js scene, OrbitControls, Reset, Fullscreen, and the
graceful-fallback contract. We extend it rather than add a second controller, keeping viewer
concerns in one place. Changes:

- **`lazy: Boolean` value.** `connect()` sets `disposed = false` and, when `lazy` is true, returns
  without booting (waits for `load()`). When false it boots on connect (preserves the current
  behavior for any non-lazy mount). We set `lazy` on both surfaces.
- **`load()` action** — bound to the *View in 3D* button. Resolves the active source (see below),
  disposes any existing scene first (so it doubles as the file-switch path), sets `urlValue` /
  `formatValue`, and `await`s `boot()`. Because `boot()` performs the `import("three")`, Three.js is
  not downloaded until this runs.
- **`selectSource()` action** — bound to the dropdown's `change`. When the viewer is already loaded
  (`--ready`), it re-runs `load()` to switch files; when resting, it is a no-op (the selection is
  read at `load()` time).
- **`showPoster()` action** — bound to *✕ image*. Disposes the scene and removes `--ready`, revealing
  the poster.
- **`teardown()` helper** — the dispose logic currently inline in `disconnect()` (cancel the RAF,
  disconnect the ResizeObserver, dispose controls/geometries/materials/renderer, remove the canvas
  DOM element) extracted into a reusable method. Called by `disconnect()`, `showPoster()`, and the
  switch path in `load()`. `boot()` must be re-entrant after a `teardown()` (it recreates renderer,
  scene, camera, controls from scratch — it already does).

**Active source resolution:** if the element contains a source `<select>` (model page, multi-file),
`load()` reads the selected option's `data-url` and `data-format`. Otherwise (file page, or a single
model file rendered without a dropdown) it uses the element's `url` / `format` values as today.

### Host wiring — model page

- **`ModelsController#show`** computes `@viewable_3d`: the model's attachments whose file extension
  is in `%w[stl 3mf obj]` (equivalently, `role == "model"` minus STEP/IGES — extension is the source
  of truth for "the viewer can parse it"), each mapped to `{ node_id, name, blob_url, format }` using
  the existing `@nodes` map and `blob_file_path`.
- **`app/views/models/show.html.erb`** — the `.model-hero` block: when `@viewable_3d.any?`, wrap it as
  the `modelviewer` element (`data-controller="modelviewer"`, `lazy` true). The existing hero content
  (image / thumb / placeholder) becomes the `fallback` (poster) target; add an empty `canvas` target
  and a control bar. Render the `<select>` only when `@viewable_3d.size > 1`. When `@viewable_3d` is
  empty, render today's hero unchanged (no wrapper). Extract the control bar into a small partial if
  it keeps the view readable.

### Host wiring — file page

- **`app/views/files/show.html.erb`** — the `:model3d` branch: add `data-modelviewer-lazy-value="true"`
  and a **View in 3D** button (`data-action="modelviewer#load"`) in the fallback. Reset/Fullscreen stay
  in the bar but are hidden until `--ready`.

### CSS (`app/assets/stylesheets/application.css`)

Extend the existing `.model-viewer` rules (currently lines ~90–105): control-bar layout, and
`--ready`-driven visibility so *View in 3D* shows only while resting and *Reset / Fullscreen / ✕ image*
show only while loaded. The dropdown shows in both states. Give the model-page canvas stage a height
consistent with the current hero.

### Backend-agnostic

Everything routes through `blob_file_path(node_id)`, which already serves bytes across chunk / share
/ s3 (redirect-to-presigned / send_file / stream). No FileLayer, sync, or storage changes. This
feature lives entirely in the maker web UI (§10 boundary is not touched).

## Testing

- **Request/controller tests** (assert the server-rendered markup — the part Rails can verify):
  - Model show with ≥2 viewable files → control bar present, a `<select>` with one option per
    viewable file carrying the right `blob` URLs and formats, `lazy` value set.
  - Model show with exactly 1 viewable file → button present, **no** `<select>`.
  - Model show with 0 viewable files → **no** control bar/button; hero markup unchanged.
  - Model show → STEP/IGES model-role files are **excluded** from the switcher.
  - File show `:model3d` → `lazy-value="true"` and a *View in 3D* action present; the viewer element
    is no longer configured to auto-boot.
  - Run green on all three backends (`bin/rails test`, `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`),
    matching the repo's existing CI legs.
- **JS behavior** (actual boot / switch / dispose / degradation): the repo has no JS test harness, so
  this is verified manually in the browser against a model with multiple STL/3MF/OBJ files — the same
  way the existing viewer is verified. The manual check covers: button loads on click, dropdown
  switches the rendered file, ✕ returns to the poster, and a WebGL/parse failure leaves the poster.

## Files touched (anticipated)

- `app/javascript/controllers/modelviewer_controller.js` — lazy + load/switch/showPoster/teardown.
- `app/controllers/models_controller.rb` — `@viewable_3d`.
- `app/views/models/show.html.erb` — hero → viewer + control bar (possibly a new `_hero_3d` partial).
- `app/views/files/show.html.erb` — `:model3d` branch made lazy + button.
- `app/assets/stylesheets/application.css` — control-bar + `--ready` state rules.
- `test/` — controller/request tests for the markup above.

## Open questions

None outstanding. STEP/IGES 3D is explicitly deferred, not unresolved.
