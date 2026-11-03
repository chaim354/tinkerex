# The maker tools program — Implementation Plan

> **For agentic workers:** `.claude/commands/execute-plan.md` is the house default (batched by file,
> parallel where independent, one capped quality review per task). Steps use checkbox (`- [ ]`) syntax.

**Spec:** `docs/superpowers/specs/2026-11-02-maker-tools-program-design.md` — read it first; the
algorithms, tables and manifest rules live there and are not repeated here.

**Goal:** sixteen browser-only tools in `tinkerex-addons` on one shared library, and two host
features — a file page that opens a tool, and a gallery in sections — so a maker reaches a tool from
the file they are looking at.

**Architecture:** the host (`tinkerex`) gains the `opens` and `category` manifest keys, a `?file=`
launch hint carried as `host.launch.fileId`/`fileName` (host level 4), a lazy `tools/open_with`
frame on the file page, and a sectioned gallery. The addons repo gains `addons/_lib/` (mesh, SVG, UI,
save panel, file opener, units, fastener data, vendored earcut), reached from each addon through a
`lib -> ../_lib` symlink, a `node --test` harness, and sixteen addons each split into a thin
`<key>.js` mount and a tested `<key>_core.js`.

**Tech Stack:** Rails 8 + Minitest + Capybara (host); plain ESM, `node:test` on Node 18, earcut
(ISC), qrcode-generator (MIT), opentype.js (MIT) (addons).

**Checkouts:** host worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/maker-tools`
(branch `claude/maker-tools`); addons worktree
`/Users/charlesschwartz/Desktop/repos/tinkerex-addons-maker-tools` (branch `claude/maker-tools`).
The two are siblings of nothing: set `ADDON_SOURCE_PATH=/Users/charlesschwartz/Desktop/repos/tinkerex-addons-maker-tools/addons`
when running the host dev server or `addons:check` against this work, and `TINKEREX_PATH=<host worktree>`
for the addons repo's scripts.

---

## How to run things (every task)

- **Addons unit tests:** `cd /Users/charlesschwartz/Desktop/repos/tinkerex-addons-maker-tools && node --test test/unit/<file>.test.js` (one file) or `bin/test` (everything).
- **Manifest check from the host:** `cd <host worktree> && LANG=en_US.UTF-8 bin/rails "addons:check[/Users/charlesschwartz/Desktop/repos/tinkerex-addons-maker-tools/addons]"` — exit 0 and `N tools OK`.
- **Host tests:** `cd <host worktree> && LIBRARY_PATH=$(mktemp -d) bin/rails test <file>` (bare `bin/rails test` errors by the hundred without `LIBRARY_PATH`). System tests: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/<file>`.
- **Ruby edits from a shell:** the tool locale is US-ASCII; run any Ruby that reads a manifest with `LANG=en_US.UTF-8`.
- **Never `git stash`** in either worktree (shared stash stacks). Restore a mutation-checked file with `git checkout -- <file>`.
- **Commit messages** go through `-F <file>`, never `-m "…"` with a backtick in it.

## The `_lib` contract (every addon task reads this)

All coordinates are **mm, Z up**; polygons are arrays of `[x, y]`; a mesh is
`{ vertices: [[x, y, z], …], faces: [[a, b, c], …] }` with outward CCW faces.

```js
// addons/_lib/mesh.js
export function circle(r, { segments = 64, cx = 0, cy = 0 } = {})            // CCW points
export function regularPolygon(n, circumradius, { cx = 0, cy = 0, rotation = 0 } = {})
export function rect(w, h, { cx = 0, cy = 0 } = {})                           // 4 points CCW
export function roundedRect(w, h, r, { segmentsPerCorner = 8, cx = 0, cy = 0 } = {}) // r clamped to min(w,h)/2
export function extrudePolygon(outer, holes = [], height, { z = 0 } = {})     // caps via earcut; any input winding
export function loft(rings, { closeBottom = true, closeTop = true } = {})     // rings: [{ z, points }], equal lengths, ascending z
export function heightmapSolid(heights, { dx, dy, zBase = 0 } = {})           // heights: rows of top z; solid from zBase
export function cylinder(r, h, { segments = 64, x = 0, y = 0, z = 0 } = {})
export function tube(ro, ri, h, { segments = 64, x = 0, y = 0, z = 0 } = {})
export function box(w, d, h, { x = 0, y = 0, z = 0 } = {})                     // x,y,z = min corner
export function merge(...meshes)                                              // reindexed copy
export function translate(mesh, dx, dy, dz)                                   // new mesh
export function rotateZ(mesh, radians)                                        // new mesh, about the origin
export function validate(mesh)   // { watertight, openEdges, nonManifoldEdges, flippedEdges }
export function stats(mesh)      // { triangles, volume, area, bounds: { min, max, size } }
export function toBinaryStl(mesh, name = "tinkerex")                          // Uint8Array
export function parseStl(bufferOrBytes)                                       // ASCII or binary; vertices deduplicated by exact key
export function parseObj(text)                                                // v/f, quads fanned, negative indices
```

```js
// addons/_lib/svg.js
export class SvgDoc {
  constructor(widthMm, heightMm)                         // width="Wmm" height="Hmm" viewBox="0 0 W H"
  path(d, attrs = CUT) ; circle(cx, cy, r, attrs = CUT) ; rect(x, y, w, h, attrs = CUT)
  line(x1, y1, x2, y2, attrs = CUT) ; polyline(points, attrs = CUT, { close = false } = {})
  text(x, y, str, attrs = {}) ; group(attrs = {})       // group returns a child builder with the same methods
  toString()                                             // the document, with the xmlns and a trailing newline
}
export const CUT = { fill: "none", stroke: "#000000", "stroke-width": 0.1 }
export const ENGRAVE = { fill: "none", stroke: "#0000ff", "stroke-width": 0.1 }
export const MARK = { fill: "none", stroke: "#999999", "stroke-width": 0.1, "stroke-dasharray": "1 1" }
export function esc(text)      // XML escape of & < > " '
export function num(n)         // up to 3 decimals, trailing zeros trimmed, "-0" never
export function arcPath(cx, cy, r, startDeg, endDeg)  // an SVG path d for a circular arc
```

```js
// addons/_lib/ui.js  — host classes only (.generator-editor .generator-side .generator-preview
// .box-field .box-field-label .btn .btn.ghost .muted .box-preview-status .box-actions .tools-grid);
// a `style` attribute where none fits; never a <style> block or a stylesheet.
export function h(tag, attrs = {}, ...children)   // class via `class`; `on<Event>` functions become listeners; `dataset` object; children: nodes, strings, arrays, null
export function layout(el)        // empties el, renders <div class="generator-editor"><div class="generator-side"></div><div class="generator-preview"></div></div>; returns { side, preview }
export function number({ label, value, min, max, step = 1, unit, onChange })   // { el, get(): Number, set(v) } — get() is NaN-safe (returns last valid)
export function select({ label, options: [{ value, label }], value, onChange })  // { el, get(), set(v) }
export function checkbox({ label, checked = false, onChange })                   // { el, get(), set(v) }
export function text({ label, value = "", placeholder, onChange })               // { el, get(), set(v) }
export function textarea({ label, value = "", rows = 6, placeholder, onChange }) // { el, get(), set(v) }
export function tabs(panels /* [{ key, label, el }] */, { active } = {})         // { el, show(key) } — buttons are .btn.ghost, the active one .btn
export function table(headers, rows, { className } = {})                         // <table class="meta"> with escaped cells
export function status()                                  // { el: <p class="box-preview-status muted" aria-live="polite">, set(text, kind = "info" | "error") }
export function debounce(fn, ms = 150)
export function fmt(n, digits = 2)                        // fixed digits, trailing zeros trimmed
```

```js
// addons/_lib/save_panel.js — reads `host` at call time; never captures it
import { host, AddonError, NameTakenError, ServiceUnavailableError, WouldReplaceError } from "@maker/addon-sdk"
export function mountSavePanel(el, ctx, { collect, load, defaultName = "untitled" })
//  collect(): { name, data, files: [{ name, contentType, body }] }  — called on Save; may throw Error(message) to refuse
//  load(data, state): hands a saved item's params back; called for host.launch.stateId on mount and from the "Open a saved…" select
//  Renders: Name <input>; "Save into <path>" + Change… (pickFolder seeded from ctx.defaultFolder / ctx.defaultFolderLabel);
//           when launched for a state: "Save as revision N+1 of <name>" checkbox (on) — off means save as new;
//           "Open a saved…" <select> over host.state.list() (newest first, "<name> · v<revision>") → load(data, state);
//           [Save] .btn; a status line.
//  Before calling host.files.save: refuses > 8 files or > 4,000,000 bytes total with a sentence naming the size.
//  Errors: the sentences of templates/addon.js (NameTaken / WouldReplace / ServiceUnavailable / AddonError); onReplace = window.confirm.
//  Returns { setStatus(text, kind), reload() }  — reload() re-reads state.list()
```

```js
// addons/_lib/open_file.js
export function mountOpenFile(el, ctx, { extensions, onFile, accept })
//  extensions: [".stl", ".obj"] for pickFile; accept: the <input type=file accept> string (defaults from extensions)
//  onFile({ name, bytes /* ArrayBuffer */, source: "library" | "device", nodeId /* library only */ })
//  On mount: if host.launch.fileId → host.files.read(fileId) → onFile with name = host.launch.fileName
//  Buttons: "Choose from your library" (only when caps["pick:file"] and caps["library:read"]) → pickFile({ extensions }) → read → onFile (name = last path segment)
//           "Choose from this device" → <input type=file> → onFile (never leaves the browser)
//  A status line for not_found (404) and ServiceUnavailableError (503, "try again").
```

```js
// addons/_lib/units.js
export const LENGTH = { mm: 1, cm: 10, m: 1000, in: 25.4, ft: 304.8 }          // mm per unit
export const MASS = { g: 1, kg: 1000, oz: 28.349523125, lb: 453.59237 }       // g per unit
export function toMm(value, unit) ; export function fromMm(mm, unit)
export function parseLength(text, defaultUnit = "mm")   // "12", "12mm", "1/4in", "3 1/2 in", "2ft" → mm, or NaN
export function formatLength(mm, unit = "mm", digits = 2)
export function inchFraction(mm, denominator = 16)      // { whole, numerator, denominator, approx }
export function cToF(c) ; export function fToC(f)
```

```js
// addons/_lib/fasteners_data.js — the tables in spec §6.15, as data only
export const METRIC   // [{ size:"M3", d:3, pitch:0.5, tapDrill:2.5, fine:{ pitch:0.35, tapDrill:2.65 }|null, clearance:{ close:3.2, normal:3.4, loose:3.6 }, nutAf:5.5, nutHeight:2.4, capHeadD:5.5, capHeadH:3, hexKey:2.5, washerId:3.2, washerOd:7, insertHole:4.0 }, …] M1.6 … M20
export const UNIFIED  // [{ size:"#4-40", dIn:0.112, tpi:40, series:"UNC", tapDrill:{ label:"#43", mm:2.26 }, clearance:{ close:2.95, normal:3.26, loose:3.66 } }, …] #2-56 … 1/2-20
export const INSERT   // [{ size:"M2", hole:3.2, length:4.0 }, …] labelled typical in the UI
export function clearanceFor(size, fit = "normal")  // mm or undefined
export function tapDrillFor(size)                   // mm or undefined
```

## Manifest entries (written up front by the orchestrator, Task 0)

Every new entry carries `api_version "1"`, `entry "<key>.js"`, `version "1.0.0"`, `author "Charles
Schwartz"`, `license "MIT"`, `category`, `min_host`, `permissions` with honest reasoning, and `opens`
where the spec gives one. An implementer edits **only** its own `addons/<key>/` directory; the index
is already written.

---

## Wave 0 — foundations (four tasks, parallel: disjoint paths)

### Task 0 (orchestrator, before dispatch): repo plumbing

**Files (addons repo):** create `package.json`, `bin/test`, `addons/_lib/.keep`, `test/unit/.keep`,
sixteen `addons/<key>/lib -> ../_lib` symlinks, the full `addons/manifests.json`; README gains a
"Testing" section and the two new manifest keys.

- [ ] `package.json` = `{ "name": "tinkerex-addons", "private": true, "type": "module" }`.
- [ ] `bin/test` (bash, `set -euo pipefail`): `node --test test/unit/` then `test/new_addon_test.sh` then `test/no_gpl_in_bundle_image_test.sh`, each echoed.
- [ ] `for k in …; do mkdir -p addons/$k && ln -s ../_lib addons/$k/lib; done` for the sixteen keys, plus the three existing (`generators`, `boxes`, `openscad`) get **no** symlink (they do not use `_lib`).
- [ ] Write `addons/manifests.json` with the 19 entries (3 existing + `category: "generate"`, 16 new).
- [ ] Commit: "Plumbing: a node test harness, a shared library directory and the sixteen manifests".

### Task L1: `_lib/mesh.js`, `_lib/preview3d.js`, earcut

**Files:** `addons/_lib/mesh.js`, `addons/_lib/preview3d.js`, `addons/_lib/earcut.js` (verbatim
from `https://ga.jspm.io/npm:earcut@2.2.4/src/earcut.js`, header comment naming the source as
`generators/makerjs.js` does), `addons/_lib/LICENSE-earcut.md` (the ISC text from the package),
`test/unit/mesh.test.js`.

- [ ] Tests first (`node --test test/unit/mesh.test.js`, expected to fail on import):
  - `extrudePolygon(rect(10,10), [], 5)`: 12 faces? No — caps via earcut give 2 triangles each, 4 walls × 2 = 8: **12 faces**, `validate().watertight === true`, `stats().volume ≈ 500` (±1e-6), bounds `[0..10, 0..10, 0..5]` for a rect centred at (5,5).
  - A square with a square hole: `validate().watertight`, volume = outer − hole exactly.
  - `tube(10, 5, 8, { segments: 64 })`: volume within 1% of `π(100−25)·8`; watertight; `loft` of three rings (rounded rects shrinking) watertight; `heightmapSolid` on a 3×3 grid watertight with volume = Σ(h − zBase)·dx·dy for a flat grid.
  - `toBinaryStl` → `parseStl` round trip: same triangle count, `validate` still watertight (dedup works), header 80 bytes, length `84 + 50n`.
  - ASCII STL parse of a hand-written two-triangle solid; `parseObj` with a quad face and negative indices → 2 triangles / correct vertices.
  - `validate` reports `openEdges: 3` for a lone triangle and `watertight: false`.
  - A clockwise outer ring is normalised: `extrudePolygon(rect reversed)` has positive volume.
- [ ] Implement `mesh.js` (earcut via `import earcut from "./earcut.js"`), then `preview3d.js`:
  `export function renderMesh(canvas, mesh, { azimuthDeg = -35, elevationDeg = 30, padding = 12 } = {})` — orthographic, painter's sort by depth, Lambert shade from a fixed light, fit-to-canvas, clears first; `export function fitCanvas(canvas)` sizes the backing store to its CSS box × devicePixelRatio. No test (canvas), but it must not touch `document` at import time.
- [ ] Mutation: flip one wall's winding in `extrudePolygon` → the `flippedEdges`/watertight assertion goes red; restore.
- [ ] Commit: "_lib: an indexed mesh with earcut caps, STL in and out, and a canvas preview".

### Task L2: `_lib/svg.js`, `_lib/ui.js`, `_lib/units.js`, `_lib/fasteners_data.js`

**Files:** the four modules, `test/unit/svg.test.js`, `test/unit/units.test.js`,
`test/unit/fasteners_data.test.js` (`ui.js` is DOM-bound: no unit test; it must not touch `document`
at import time).

- [ ] Tests first: `SvgDoc(100, 50).toString()` starts `<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="50mm" viewBox="0 0 100 50">`; `esc('a<b&"c"')`; `num(1.23456) === "1.235"`, `num(2) === "2"`, `num(-0.0001) === "0"`; a `group` nests; `arcPath` of 0→90° contains ` A `.
  `parseLength("1/4in")` = 6.35; `"3 1/2 in"` = 88.9; `"12"` with default mm = 12; `"2ft"` = 609.6; `"x"` → NaN. `inchFraction(6.35, 16)` → `{ whole: 0, numerator: 4, denominator: 16 }` reduced to `1/4` (reduce in the function: expose `numerator: 1, denominator: 4`). `cToF(100) === 212`.
  `clearanceFor("M3")` = 3.4, `("M3", "close")` = 3.2, `tapDrillFor("M8")` = 6.8, `tapDrillFor("#4-40")` = 2.26, `METRIC.length >= 12`, every METRIC row has `tapDrill === d - pitch` within 0.01 (that is the rule the table follows).
- [ ] Implement. Fastener values are the spec's tables (§6.15 and the plan's contract); do not invent a size the spec does not list.
- [ ] Mutation: change M3 normal clearance to 3.5 → red; restore.
- [ ] Commit: "_lib: SVG in millimetres, the shared form widgets, units and the fastener tables".

### Task L3: `_lib/save_panel.js`, `_lib/open_file.js`

**Files:** the two modules; `test/unit/save_panel.test.js` for the pure helpers they export:
`export function saveSizeProblem(files)` (returns a sentence or null: `> 8` files, total bytes of
string bodies as UTF-8 + binary bodies `> 4_000_000`) and `export function basename(path)`; the
DOM half is verified in the browser pass. Read `docs/addon-api-v1.md` §3 and `templates/addon.js`
in full first — the live-binding rule, `folderNodeId` never defaulted from a cancelled pick,
`result.cancelled`, 409 vs 422.

- [ ] Tests first for the two helpers (9 files → sentence; a 4,000,001-byte string → sentence naming "4,000,001"; 3 small files → null; `basename("/Projects/a/b.stl")` → `"b.stl"`).
- [ ] Implement per the contract above. The `@maker/addon-sdk` import must stay a bare specifier (host pin). `mountSavePanel` must work when `caps["pick:folder"]` is false (hides Change…) and when `state.list()` fails (hides the select, logs via status).
- [ ] Commit: "_lib: one save panel and one file opener for every tool".

### Task H: host — Open with (level 4) and gallery sections

**Files (host worktree):** modify `app/services/maker/addons/registry.rb` (`opens`, `category`
on `Addon` and `build`), `app/services/maker/addons/check.rb` (report dropped `opens` entries),
`app/services/maker/addons/host.rb` (`LEVEL = 4`), `app/controllers/tools/addons_controller.rb`
(`?file=` hint, `launch` keys, destination step), `app/controllers/tools/home_controller.rb`
(`open_with`; `new_menu` filter; sections), `app/views/tools/home/index.html.erb` (sections),
create `app/views/tools/home/open_with.html.erb`, modify `app/views/files/show.html.erb` (the
frame), `config/routes.rb` (`tools/open_with` above `tools/:key`), `app/javascript/maker/addon_sdk.js`
(`launch` getter), `test/fixtures/addons/manifests.json` + `test/fixtures/addons/sdk-fixture/sdk.js`
(`opens: [".txt"]`, `category`, render `launch.fileId`/`fileName`), `docs/addon-api-v1.md`,
`docs/invariants/addons.md`, and the tests named in spec §3.5/§4. Read `docs/invariants/addons.md`
in full before editing (the `?in=`/`?state=` hint bullets are the pattern to copy).

- [ ] Tests first, file by file, each run red then green with `LIBRARY_PATH=$(mktemp -d) bin/rails test <file>`:
  `test/services/maker/addons/registry_test.rb` (opens + category), `test/services/maker/addons/check_test.rb`,
  `test/services/maker/addons/host_test.rb` (ledger → 4), `test/controllers/tools/addons_controller_test.rb`
  (`?file=` cases incl. the destination; use `project_folder_rows!`, never a real mkdir),
  `test/controllers/tools/home_controller_test.rb` (sections, `new_menu`, `open_with`),
  the web request test for the file page frame, `test/system/addon_sdk_test.rb` (the Open-with journey).
- [ ] Implement. `#find_launch_file(raw)`: `return unless raw.is_a?(String)`; `current_user.nodes.present.find_by(node_id: raw, kind: "file")` (check the model's live scope name — `Node.present` is used by `Maker::DeadNodes`; use whatever `#destination_from_param` uses for folders). `addon_ctx[:launch] = { stateId:, fileId:, fileName: }`. In `tool_destination_node_id`, the new step calls `owning_project_folder(parent_id) || parent_id` exactly as step 3 does. SDK: `get launch() { return { stateId: null, fileId: null, fileName: null, ...this._ctx.launch } }`.
- [ ] Gallery: `@sections = [["Make a file", generate…], ["Look inside a file", inspect…], ["Calculate and look up", reference…], ["Other", nil…]].reject { |_, list| list.empty? }`, each rendered with the existing `.tools-section`/`.tools-section-head`/`.tools-grid` classes; **no stylesheet change**. `new_menu`: `select { |a| a.available? && [nil, "generate"].include?(a.category) }`.
- [ ] Docs: `docs/addon-api-v1.md` (two keys in the optional table, level table row 4, `host.launch` fields, an "Open with" paragraph under `host.files.read`), `docs/invariants/addons.md` (three bullets, spec §3.6), `test/docs_hygiene_test.rb` must stay green.
- [ ] Mutations (report actual output): remove `fileName` from `addon_ctx` → the system test and the controller test go red; remove the `is_a?(String)` guard → the array case goes red; move the `tools/open_with` route below `tools/:key` → the `open_with` test 404s.
- [ ] Run `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/addons test/controllers/tools test/system/addon_sdk_test.rb test/docs_hygiene_test.rb test/integration/web` and report counts.
- [ ] Commit: "A file page opens the tools that read its kind, and the gallery groups its add-ons".

---

## Wave 1 and 2 — the sixteen tools (parallel: each touches only `addons/<key>/` and `test/unit/<key>.test.js`)

Every tool task follows the same steps; the per-tool section lists only what differs.

- [ ] **Step 1:** read the spec's subsection for the tool, the `_lib` contract above, `docs/addon-api-v1.md` §3, and `templates/addon.js` (the save-error sentences and the live-binding rule).
- [ ] **Step 2:** write `test/unit/<key>.test.js` against `addons/<key>/<key>_core.js` — the assertions named below — and run it red.
- [ ] **Step 3:** write `<key>_core.js` (pure: no `document`, no `host`, no DOM at import or call time) until green.
- [ ] **Step 4:** write `<key>.js`: `export default { mount(el, ctx) { … } }` using `layout(el)` from `./lib/ui.js`, the fields, a debounced render into the preview (`SvgDoc` output inlined via `innerHTML` of a container for SVG; `renderMesh` on a `<canvas>` for STL; a `<canvas>` for G-code), and `mountSavePanel` / `mountOpenFile` from `./lib/…` as the spec says. `collect()` names output files from the item name slugged (`name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()`), content types `image/svg+xml`, `model/stl`, `text/csv`, `text/markdown`. `load(data)` sets every field and re-renders. Read `host` at call time only.
- [ ] **Step 5:** `node --test test/unit/<key>.test.js` green; from the host worktree `LANG=en_US.UTF-8 bin/rails "addons:check[/Users/charlesschwartz/Desktop/repos/tinkerex-addons-maker-tools/addons]"` reports no problem for your key (other keys may still be missing their entry file while their tasks run — ignore those lines).
- [ ] **Step 6:** the named mutation, actual output reported, file restored with `git checkout --`.
- [ ] **Step 7:** commit only your files: `git add addons/<key> test/unit/<key>.test.js` with a message like "<Title>: <what it makes>".

### Task T1 `gears` — core exports and tests
`spurGear({ module, teeth, pressureAngleDeg = 20, bore = 0, hub = 0, pointsPerFlank = 12 })` → `{ outline: points, holes: [points], pitchRadius, outerRadius, rootRadius, baseRadius }`;
`rack({ module, length, pressureAngleDeg, height })` → `{ outline }`; `gearPair({ module, teeth1, teeth2, … })` → `{ gears: [{ outline, holes, cx, cy }], centreDistance }`;
`gearSvg(spec)` → SvgDoc string; `gearMesh(spec, thickness)` → mesh.
Tests: `outerRadius === module*(teeth+2)/2`; `pitchRadius === module*teeth/2`; the outline has `teeth` local maxima of radius; `centreDistance === module*(t1+t2)/2`; `validate(gearMesh(...)).watertight` with a bore. Mutation: addendum `m` → `1.1m` → red.

### Task T2 `hole-patterns`
`boltCircle({ count, pcd, startDeg = 0 })` → `[{x,y}]`; `grid({ nx, ny, pitchX, pitchY })`; `line({ count, pitch })`; `holeDiameter({ size, fit })` via `fasteners_data`; `patternSvg({ holes, diameter, outline: { kind: "rect"|"circle"|null, margin, cornerRadius }, crosshairs: true })`; `plateMesh({ holes, diameter, outline, thickness })`.
Tests: 6 holes on PCD 50 all at r = 25 and 60° apart; a 3×2 grid has 6 holes; `holeDiameter({ size: "M3", fit: "normal" }) === 3.4`; the SVG contains `count` `<circle` cut elements plus crosshairs; the plate mesh is watertight with volume = plate − holes within 1%. Mutation: start angle ignored → red.

### Task T3 `patterns`
`livingHinge({ width, height, margin, slotLength, slotWidth, gap, rowPitch })` → `{ cuts: [[points]…] }` (each slot a closed rounded path), `honeycomb({ width, height, margin, cellAcrossFlats, wall })`, `slotGrid({ width, height, margin, slotW, slotH, pitchX, pitchY })`, `patternSvg(kind, params)`.
Tests: every cut point lies within `[margin, width−margin] × [margin, height−margin]`; a 100×50 hinge with slot 20/gap 5/rowPitch 5 has the computed count (assert against a hand-counted value you derive and state in the test); honeycomb cell count grows with area. Mutation: margin ignored → the bounds test goes red.

### Task T4 `test-pieces`
`kerfComb({ from = 0.10, to = 0.60, step = 0.05, slotLength })` → `{ slots: [{ width, x }], labels }`; `fingerFit({ tab, offsets = [-0.2,-0.1,0,0.1,0.2] })`; `toleranceTestMesh({ pin = 5, clearances = [0.1,0.2,0.3,0.4,0.5], height })` (pegs + holes as overlapping shells: a base plate with holes via `extrudePolygon`, pegs via `cylinder`); `insertTestMesh({ sizes: ["M2","M2.5","M3","M4"] })` from `INSERT` holes ±0.2; `pieceSvg(kind, params)`.
Tests: 11 slots from 0.10 to 0.60; each slot's label text equals its width to 2 decimals; both meshes watertight; the tolerance plate has `clearances.length` holes. Mutation: `step` ignored → red.

### Task T5 `labels`
`parseLabels(text)` → `[{ line1, line2, url }]` (split on `|`, trimmed, blank lines skipped); `layoutSheet({ labels, labelW, labelH, sheet: { w, h } | null, margin, gap })` → `[{ labels: [{ index, x, y }] }]` (one page per sheet; `null` sheet = one label per page); `qrModules(text, { level = "M" })` → boolean grid via `./qrcode.js` (vendored `https://ga.jspm.io/npm:qrcode-generator@1.4.4/qrcode.js` as `addons/labels/qrcode.js`, `LICENSE-qrcode-generator.md` beside it); `labelSvg(page, params)`.
Tests: 7 labels of 50×25 on A4 with 10 margin/2 gap → 1 page, positions in-bounds, none overlapping; `qrModules("HELLO")` is square with the three finder patterns (top-left 7×7 dark ring); text is escaped (`<` in a label). Mutation: gap ignored → overlap test goes red.

### Task T6 `text-outline`
Vendor `https://ga.jspm.io/npm:opentype.js@1.3.4/dist/opentype.module.js` as `addons/text-outline/opentype.js` with `LICENSE-opentype.md` (MIT, from the package) — it inlines its two dependencies and imports nothing. `textPaths(font, { text, sizeMm, letterSpacing = 0, lineHeight = 1.2, align = "left" })` → `[{ d, advance }]` per line with `font.getPath(line, x, baseline, sizeMm)`, where `unitsPerEm` maps so `sizeMm` is the em height in mm; `outlineSvg(paths, { strokeOnly })`.
Tests: build a minimal font in the test with `opentype.Font` + one `Glyph` (a square path) and check `textPaths` returns one path per line, the square's extent ≈ `sizeMm × (glyph units / unitsPerEm)`, and alignment shifts x. If `import "./opentype.js"` fails under node, report it and stop — the spec drops the tool. Mutation: `letterSpacing` ignored → red.

### Task T7 `parts`
`spacerMesh({ od, id, height, shape: "round"|"hex" })`, `washerMesh`, `tubeMesh`, `plateMesh({ w, d, t, hole, inset })` (four corner holes), each via `extrudePolygon` with the hole as a ring.
Tests: all watertight; spacer volume within 1% of `π(od²−id²)/4·h` (round, 64 segments); hex spacer uses `regularPolygon(6, …)` across-flats conversion `circumradius = af / √3`; plate has 4 holes (face count parity against a plate with none). Mutation: `id` ignored → volume test red.

### Task T8 `lithophane`
`toHeightmap(gray /* Float32Array 0..1 rows×cols */, { tMin, tMax, invert })` → heights; `lithophaneMesh(heights, { pixelMm, frame })` via `heightmapSolid` + a frame ring of `tMax` (`extrudePolygon` of outer rect minus inner rect, overlapping shell); `capResolution({ cols, rows, maxPixels = 35000 })` → `{ cols, rows, scale }`; `luminance(r, g, b)` (Rec. 709).
Tests: a 4×4 gradient grid → vertex count `(cols+1)(rows+1)` on top, watertight, darker pixel thicker, invert flips it, `capResolution` keeps aspect and stays under the cap, the STL byte length for the capped size is under 3,500,000. The mount decodes the image on a canvas (`createImageBitmap` or `<img>` + `drawImage`, `getImageData`). Mutation: `invert` ignored → red.

### Task T9 `gridfinity`
Constants exported from `gridfinity_core.js` (`PITCH = 42`, `GAP = 0.5`, `HEIGHT_UNIT = 7`, `BASE = [{ chamfer: 0.8 }, { vertical: 1.8 }, { chamfer: 2.15 }]`, `LIP = [{ chamfer: 0.7 }, { vertical: 1.8 }, { chamfer: 1.9 }]`, `CORNER_R = 3.75`, `WALL = 1.2`, `FLOOR = 1.0`). `binMesh({ x, y, z, lip = true, dividersX = 0, dividersY = 0 })` — outer rings bottom→top (base profile then straight wall then lip profile), inner rings top→floor, one `loft`-built closed shell; dividers as `box` shells overlapping the floor and walls. `baseplateMesh({ x, y })` — top face = rect minus `x·y` rounded-square pockets (earcut), each pocket a socket loft down to a floor at `−4.75`, outer walls, bottom; thickness `4.75 + FLOOR`.
Tests: a 2×1×3 bin has bounds `83.5 × 41.5` footprint and height `21 + 4.4` with the lip / `21` without; watertight with and without dividers; the base bottom is `35.6` wide for 1 unit; baseplate 2×2 has 4 pockets (count the top-face holes by the ring count in the core's intermediate output) and is watertight. Mutation: `GAP` 0 → the footprint test goes red.

### Task T10 `cut-list`
`packLengths({ parts: [{ label, length, qty }], stock: [{ length, qty | Infinity }], kerf })` → `{ pieces: [{ stockLength, cuts: [{ label, length, x }], waste }], unplaced: [] }` first-fit-decreasing; `packSheets({ parts: [{ label, w, h, qty, rotate }], sheets: [{ w, h, qty }], kerf })` → `{ sheets: [{ w, h, placements: [{ label, x, y, w, h, rotated }] }], unplaced }` shelf packing by decreasing height, rotating a part when allowed and it fits a shelf better; `cutListCsv(result)`; `layoutSvg(sheetOrPiece)`.
Tests: lengths — parts 3×900 + 2×400 from 2440 stock with kerf 3 → 2 pieces, every cut within the stock, `x` gaps ≥ kerf; sheets — 4 of 600×400 on 1220×2440 → 1 sheet, no overlaps (pairwise), all inside; an oversize part lands in `unplaced`; CSV quotes a label with a comma. Mutation: kerf ignored → the gap assertion goes red.

### Task T11 `gcode`
`parseGcode(text)` → `{ slicer, meta: { time, timeSource, filamentMm, filamentG, layerCount, layerHeight, firstLayerHeight, nozzleTemp, bedTemp, settings: [{ key, value }] }, layers: [{ z, segments: [{ x0, y0, x1, y1, extruding }] }], bounds: { extruding, all }, feed: { min, max }, mode: "fdm" | "cnc", estimatedFromMoves: boolean }`. Rules in spec §6.11; arcs subdivided to ≤ 1 mm chords; relative/absolute honoured; a layer in FDM = a Z change followed by extrusion; in CNC every distinct Z of a cutting move. `summaryMarkdown(parsed, fileName)`.
Tests: fixtures as template strings for Cura (`;TIME:3600`, `;LAYER_COUNT:2`, `;LAYER:0`), PrusaSlicer (`; estimated printing time (normal mode) = 1h 2m 3s`, `; filament used [mm] = 123.4`, `;LAYER_CHANGE`/`;Z:0.2`), OrcaSlicer, a CNC file with G2 arcs and no E: time parsed to seconds, layer counts, bounds of extruding moves exclude a travel to (100,100), `mode` detection, arc subdivision yields ≥ 2 segments, G91 relative move accumulates. Mutation: `G91` handling removed → red.

### Task T12 `mesh-info`
`detectFormat(name, bytes)`; `parse3mf(bytes, JSZip, DOMParser)` → mesh (injected constructors so the test can pass Node's — use a tiny hand-built zip in the test via JSZip from the host checkout? No: `jszip` is a host pin not present in this repo. The test builds the 3MF XML and calls `parse3mfModelXml(xmlText, { DOMParser })` directly; the zip unwrap is a 10-line function exercised in the browser pass). `meshStats(mesh)` via `stats` + `validate`; `materials` table; `estimateCost({ volumeMm3, areaMm2, material, infill, walls, lineWidth, topBottomMm, pricePerKg, hours, watts, tariff })` → `{ effectiveVolumeCm3, grams, filamentM, materialCost, energyCost, total }` per spec §6.12; `spoolRemaining({ gross, empty, density, diameter })`; `costMarkdown(...)`.
Tests: unit cube STL volume 1, area 6; OBJ quad; 3MF XML with two objects and a build transform (translate) → combined bounds; cost of 10 cm³ PLA at 100% infill = 12.4 g; spool 1000 g gross − 250 g empty at PLA 1.75 → metres. Mutation: density table PLA → 1.0 → red.

### Task T13 `electronics`
`colorCode({ bands: ["red","violet","orange","gold"] })` → `{ ohms: 27000, tolerance: 0.05 }` and `bandsFor(ohms, { bands: 4|5|6 })`; `smdCode("473")` → 47000, `"4R7"` → 4.7, `"01C"` (EIA-96) → 10000; `eSeries(n)` with E24 listed and E96 computed; `nearest(value, series)`; `bestPair(target, series)` → `{ series: [a,b], parallel: [a,b], error }`; `divider`, `ledResistor`, `ohms`, `capCode("104")` → 100e-9, `awg(n)` → `{ dMm, areaMm2, ohmsPerM, ampacity }`, `voltageDrop({ awg, metres, amps })` round trip.
Tests: the colour and SMD examples above; `eSeries(96)` equals the standard 96-value list written in the test; `nearest(4700, 24) === 4700`; `bestPair(5000, 24).error < 0.01`; `awg(18).dMm ≈ 1.024`; divider 12 V with 10k/10k → 6 V. Mutation: the EIA-96 multiplier table → red.

### Task T14 `shop-math`
`rpm({ vcMPerMin | sfm, dMm })`, `feed({ rpm, flutes, chipLoad })`, `CHIPLOAD` table, `stepsPerMm({ steps = 200, microsteps = 16, teeth, pitch })`, `leadscrewStepsPerMm({ steps, microsteps, lead })`, `beltLength({ c, t1, t2, pitch })`, `centreDistance({ L, t1, t2, pitch })`, `ratioChain([[t1,t2],…])`, `compoundMiter({ sides, tiltDeg })` → `{ bevelDeg, miterDeg }`, `boardFeet({ tIn, wIn, lFt })`, `shelfSag({ loadN, spanMm, widthMm, thickMm, material })` with the E table, `convert(value, from, to)` over length/mass/temperature/area/volume/force/torque/pressure/speed.
Tests: `compoundMiter({ sides: 4, tiltDeg: 0 })` → bevel 45, miter 0; `tiltDeg: 90` → bevel 0, miter 45; `stepsPerMm({ teeth: 20, pitch: 2 })` → 80; `beltLength` for equal pulleys `2C + πD`; `centreDistance(beltLength(c)) ≈ c`; `boardFeet(1, 12, 1)` → 1; `convert(1, "in", "mm")` → 25.4. Mutation: `sin`↔`cos` in the miter → red.

### Task T15 `fasteners`
`rows({ system: "metric"|"unified"|"insert", query })` → filtered rows from `fasteners_data`; `detail(size)` → every field with labels and units; `search` matches `M3`, `m3`, `3mm`, `#6`, `1/4`.
Tests: `rows({ system: "metric", query: "m3" })` has one row; `detail("M6").hexKey === 5`; an unknown size → `undefined`; insert rows carry `typical: true`. Mutation: query case folding → red.

### Task T16 `laser-settings`
`validateRecord(r)` → `[]` or messages (material and operation required, power 0–100, speed > 0, passes ≥ 1); `normalise(r)` (trim, numbers); `filterRecords(records, query)`; `sortRecords(records, key)`; `toCsv(records)` (RFC 4180 quoting); `fromCsv(text)` (round trip); `NOTEBOOK_NAME = "Laser settings"`; `findNotebook(states)` → the state with that name, newest.
Tests: round trip of a record with a comma, quote and newline in `notes`; validation messages; filter by material substring; `findNotebook` prefers the newest. The mount: records live in the panel's `collect().data.records`; on mount `host.state.list()` → `findNotebook` → load; Save always revises that item when it exists (`stateId`) and creates it otherwise — the save panel's "revision" checkbox is hidden for this tool. Mutation: CSV quoting removed → red.

---

## Wave 3 — the browser pass, CI and the two PRs (orchestrator)

- [ ] Host dev server from the host worktree with `ADDON_SOURCE_PATH=<addons worktree>/addons` (memory: dev-server recipe); open every tool; change fields; Save one output per generator into a project folder; open `/files/<id>` of a `.gcode`, `.stl`, `.png`, `.ttf` and follow "Open in …"; screenshot each tool.
- [ ] `bin/test` in the addons worktree; `addons:check` clean; `bin/ci` in the host worktree with `TINKEREX_SYNC_DIR` set; the three RUN counts equal.
- [ ] Addons README: the two keys, `_lib`, testing section. Commit, push both branches, open both PRs (the addons PR names the host PR and the deploy order: either), `bin/log arc --from-pr` for the host PR.
