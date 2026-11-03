# The maker tools program — sixteen browser tools and the two workflows that carry them

**Date:** 2026-11-02 · **Repos:** `chaim354/tinkerex` (the host: two workflow features) and
`chaim354/tinkerex-addons` (the tools: sixteen bundles and a shared library).
**Owner's request:** "build all the tools you think that a maker could need and the workflows that
would support it." The owner delegated the choice of tools; every decision below was made without
them and is recorded so it can be reversed cheaply.

## 1. Where tools stand today

- `/tools` lists three add-ons: **Generators** (maker.js, browser-only), **Box Generator** and
  **OpenSCAD** (each needs a GPL sidecar, so each is greyed out on any deployment without one — the
  public demo on OVH today). Built in: the calculator, Measure, the viewers, the editor.
- A tool is reached **tool-first** only: the gallery, New ▾, or a pin. A file in the library never
  leads to a tool, except back to the one that made it ("Edit in Box Generator").
- The gallery is a flat grid. Three cards do not need grouping; nineteen do.
- The host SDK is at level 3: text or binary output, reading a picked file, saved-state revisions.
  `maker:read` (inventory, projects, BOM) is `false` and stays so — nothing here reaches maker data.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Where a tool lives | **A bundle in `tinkerex-addons`**, never a Rails page | Publishing a bundle is the deploy; Rails is never rebuilt (§14c). The calculator is the one built-in and the reason is structural (a modal over every page). |
| Sidecars | **None.** Every new tool is browser-only | It then runs on every deployment including the demo, carries no GPL, and holds no Puma thread (the proxy is synchronous, §14c). |
| Shared code between bundles | **`addons/_lib/`**, reached from each bundle as `./lib/<module>.js` through a per-addon symlink `addons/<key>/lib -> ../_lib` | The asset proxy serves only `<key>/<path>` and refuses `..`, so a bundle cannot import a sibling directory; a host pin would couple the tools to a Rails deploy; copies drift (the three `folder_field.js` copies already do). Symlinks are what `addons:check` already allows ("inside PATH by realpath"), Docker `COPY` keeps them, nginx follows them. |
| How tools are tested | **`node --test`** over pure core modules (`<key>_core.js`, `_lib/*`), plus a browser pass of every tool by hand before the PR, plus the host's own system test for the workflow | The addons repo has no JS test harness and must stay build-free: `node:test` needs no dependency. UI wiring is thin by construction; its proof is the browser pass, stated in the PR. |
| Categories | Three: `generate`, `inspect`, `reference` | Enough to group nineteen cards and to decide what New ▾ lists; a fourth would be invented. |
| "Open with" placement | **The file page**, as a lazy frame; **not** the right-click menu | The menu is built per row on the Files index, and listing tools there would read the addon registry on every Files render — on an outage that is a slow Files page for a maker who never opened /tools (the reason `Maker::AddonOrigin` never touches the registry). The file page already pays one registry read when the file has an origin. |
| `min_host` per tool | 1 for a pure calculator, 2 for one that reads a file, 3 for one that revises saves. **Never 4** | The two PRs then deploy in either order: a level-3 host ignores `opens`/`category` and `launch.fileId` reads `null`, and the tool still works via its own picker. |
| Vendored libraries | **earcut** (ISC), **qrcode-generator** (MIT), **opentype.js** (MIT); each with `LICENSE-<name>.md` beside it, as `generators/LICENSE-makerjs.md` is | Polygon-with-holes triangulation, QR codes and font outlines are not worth rewriting; all three are permissive and ship as single-file ESM from jspm, the way maker.js was vendored. |
| Output size | A tool keeps a save under the host cap (8 files, 4,000,000 bytes); STL generators cap their own resolution | A refused save after a minute of work is the worst outcome; the cap is checked before the save and said in the UI. |

## 3. Host workflow A — a file opens a tool (host level 4)

**What the maker sees.** A file page gains, beside Download, one button per tool that can open that
kind of file: "Open in G-code Inspector", "Open in Model Stats". Clicking one opens
`/tools/<key>?file=<node_id>`; the tool reads the file at once and starts its save in that file's
folder.

### 3.1 The manifest: `opens`

`"opens": [".gcode", ".nc"]` — the extensions a tool can open. `Registry.build` normalises: array
only (anything else → `[]`); each entry a String, stripped, lowercased, a leading dot optional on
input and always present on the addon (`addon.opens == [".gcode", ".nc"]`); an entry that is not
`/\A\.?[a-z0-9]+\z/i` after stripping is dropped. `Maker::Addons::Check` reports each dropped entry
(`opens: "g code" is not an extension`) so the author learns; `Registry` itself stays silent and
serves the rest, as every optional key does.

### 3.2 The hint: `?file=`

`Tools::AddonsController#show` reads `params[:file]` exactly as it reads `?in=` and `?state=`: a
String only, resolved to one of `current_user`'s **live file** nodes (`kind: "file"`, not deleted);
any miss — a folder, a tombstone, a stranger's node, an array — is `nil`, never an error. A link
that outlived its file must not take the tool down.

`addon_ctx[:launch]` becomes `{ stateId:, fileId:, fileName: }`, the last two `nil` when there is
no file. The name travels because a bundle needs it (to name its output, to tell `.stl` from
`.obj`) and `host.files.read` answers bytes with no name.

**Where the save starts** (`#tool_destination_node_id`) gains a step between `?in=` and `?state=`:
the file's folder, **mapped up to its owning project folder** when it sits inside one, for the
reason step 3 already maps: a save into the raw category folder meets the terminal 422 while the
project folder meets the 409 question. Order: `?in=`, `?file=`, `?state=`, last output, root.

### 3.3 The SDK

`host.launch` answers `{ stateId: null, fileId: null, fileName: null, ...ctx.launch }`, so a bundle
on an older host reads nulls, never `undefined`. `Host::LEVEL` becomes **4**. No capability flips —
the same reasoning as level 3: this is the existing `library:read` door being pointed at a file by
the host, and a capability that answers `true` wherever `library:read` does carries nothing.
`host_test.rb`'s ledger and the rendered-ctx literal both move to 4.

### 3.4 The frame: `GET /tools/open_with?file=<id>`

`Tools::HomeController#open_with` renders, `layout: false`, a `<turbo-frame id="open-with">`
holding one `.btn` link per **available** addon whose `opens` includes the file's extension
(`File.extname(name).downcase`), linking `tools_addon_path(key, file: id)`. Unknown or foreign file,
no extension, or no match → the frame renders empty. Declared **above** `tools/:key` in
`config/routes.rb`, as `tools/new_menu` is, or it is read as an addon key.

`files/show.html.erb` places `<turbo-frame id="open-with" src=… loading="lazy">` in `.page-actions`
after the origin button. The page's own render never touches the registry; the frame does. The
public file page (`Public::`) never gets it.

### 3.5 Tests (host)

- `registry_test.rb`: `opens` normalisation (dot added, case folded, non-array → `[]`, bad entries
  dropped); mutation: drop the regex → the bad-entry test goes red.
- `check_test.rb`: a dropped `opens` entry is reported with its spelling.
- `addons_controller_test.rb`: `?file=` of the user's own live file → `ctx.launch.fileId` and
  `fileName`; a folder, a tombstone, a stranger's node, an array → both `nil`, page 200; the
  destination is the file's folder, mapped up inside a project (the project-folder fixture, port-free:
  `project_folder_rows!`).
- `home_controller_test.rb`: `open_with` lists matching available tools only; empty for no match,
  for a foreign file and for a greyed tool.
- `files_controller_test.rb` (web): the frame is present with the right `src` on a file page and
  absent on the public file page.
- `test/system/addon_sdk_test.rb`: the `sdk-fixture` manifest declares `opens: [".txt"]`; a `.txt`
  file page shows "Open in SDK Fixture"; following it, the fixture renders `host.launch.fileId`
  and `fileName` into the DOM. Mutation: drop `fileName` from `addon_ctx` → red.

### 3.6 Docs

`docs/addon-api-v1.md`: `opens` in the optional-keys table; level 4 in the level table;
`host.launch` gains `fileId`/`fileName` with the hint semantics; a short "Open with" paragraph.
`docs/invariants/addons.md`: three bullets — `?file=` is a hint like `?in=`; the frame is lazy and
the right-click menu deliberately has no entry; `fileName` travels because `read` has no name.
`tinkerex-addons/README.md`: the key in its optional table.

## 4. Host workflow B — a gallery in sections

**Manifest:** `"category": "generate" | "inspect" | "reference"`. Anything else, including absent,
is `nil`. Cosmetic, like `layout`: nothing gates on it.

**Gallery (`tools/home/index.html.erb`):** the add-ons grid becomes up to four sections in a fixed
order — *Make a file* (`generate`), *Look inside a file* (`inspect`), *Calculate and look up*
(`reference`), *Other* (nil) — each a heading and a `.tools-grid`; an empty section is not drawn.
Every card stays an `.addon-card`, so `home_controller_test.rb`'s card count is unchanged.

**New ▾ (`#new_menu`):** lists available addons whose category is `generate` **or nil**. An inspector
or a reference opened from "New" makes nothing in the folder the menu was opened from. The three
existing manifests get `category: "generate"` in the addons PR; until then nothing changes.

**Tests:** `registry_test.rb` (the three names pass, anything else is nil);
`home_controller_test.rb` (sections appear only when populated, in order; `new_menu` omits an
`inspect` and a `reference` addon and keeps a nil one). Docs: the key in `addon-api-v1.md` and the
README table.

## 5. The shared library (`tinkerex-addons`)

- `package.json` — `{ "name": "tinkerex-addons", "private": true, "type": "module" }` and nothing
  else: it makes `.js` test files ESM. Not served (nginx serves `addons/` only), no dependencies, no
  build step. `bin/test` runs `node --test test/unit/` then the two shell tests.
- `addons/_lib/` — never an addon (`addons:check` reads manifests, not directories). Each addon
  directory holds `lib -> ../_lib`. Modules:
  - **`mesh.js`** — an indexed triangle mesh `{ vertices: [[x,y,z]…], faces: [[a,b,c]…] }`, outward
    CCW. `extrudePolygon(outer, holes, height, {z})` (earcut for the caps), `loft(rings, {closeBottom,
    closeTop})` over rings of equal point count, `roundedRect(w,h,r,{segmentsPerCorner,cx,cy})`,
    `circle(r,{segments})`, `regularPolygon`, `cylinder`, `tube`, `box`, `heightmapSolid(grid, dx, dy,
    zBase)`, `merge`, `translate`, `rotateZ`, `validate(mesh) → {watertight, openEdges, nonManifold}`
    (every edge in exactly two faces, opposite directions), `stats(mesh) → {triangles, volume, area,
    bounds}` (signed tetrahedra), `toBinaryStl(mesh, name) → Uint8Array`, `parseStl(buffer)` (binary
    when `84 + 50n` matches the length, else ASCII), `parseObj(text)`. **Every generator's test asserts
    `validate(...).watertight`**; overlapping closed shells are allowed in one STL (slicers union them),
    so dividers and holes-by-overlap need no CSG.
  - **`preview3d.js`** — a flat-shaded isometric painter's-algorithm render of a mesh onto a canvas,
    with fit-to-view. No three.js: the host's viewer pins are host-internal.
  - **`svg.js`** — an SVG document in mm (`width="…mm"`, `viewBox` in mm) with `path`, `circle`,
    `rect`, `text`, `polyline`, `group`, hairline cut strokes; `serialize()`.
  - **`ui.js`** — `h(tag, attrs, children)`, `field(label, input)`, `number(opts)`, `select(opts)`,
    `tabs(panels)`, `debounce`, `fmt(n, digits)`, a two-column `.addon-layout` (form left, preview
    right) every tool renders into.
  - **`save_panel.js`** — the one save UI: name, "Save into" (pickFolder, seeded from
    `ctx.defaultFolder`), Save, status with the 409/422/503 sentences the template already has; when
    `host.launch.stateId` names a saved item it offers "Save as revision N+1" and "Save as new"; a
    "Load a saved…" select over `state.list()` hands `data` to the tool's `load(data)`. API:
    `mountSavePanel(el, ctx, { collect: () => ({ name, data, files }), load })`.
  - **`open_file.js`** — `mountOpenFile(el, ctx, { extensions, onFile: ({name, bytes}) })`: reads
    `host.launch.fileId` at once when present, else offers "Choose from your library" (pickFile) and
    "Choose from this device" (`<input type=file>`), which never leaves the browser.
  - **`units.js`** — mm/in/cm/m/ft, g/oz/lb, °C/°F, with `parseLength("1/4in")` reusing the
    calculator's conventions in spirit (not its code).
  - **`fasteners_data.js`** — the one copy of the fastener tables (`fasteners`, `hole-patterns`,
    `test-pieces`, `parts` all read it).
  - **`earcut.js`** + `LICENSE-earcut.md`.
- `test/unit/*.test.js` — every module above has a test file; `mesh.test.js` is the backbone
  (watertightness of each primitive, STL write→parse round-trip byte-exact triangle count, volume of
  a tube within 1% of π(ro²−ri²)h at 64 segments, earcut holes).

## 6. The sixteen tools

Each is `addons/<key>/<key>.js` (mount: layout, fields, wiring — thin) + `<key>_core.js` (pure:
geometry, parsing, tables — tested) + `lib -> ../_lib`, and one manifest entry. Every manifest
carries `version "1.0.0"`, `author "Charles Schwartz"`, `license "MIT"`, honest `permissions`
reasoning, and `category`. A tool that saves declares `library:write`; one that reads declares
`library:read` (or `files.read` answers 403). All SVG output is in mm with hairline strokes.

### Make a file (`generate`)

**6.1 `gears` — Gear Generator** (`min_host: 3`). Involute spur gear (module, teeth, pressure angle
20°/14.5°, bore, optional hub circle), rack (module, length), and a meshing pair with its centre
distance `m(z₁+z₂)/2`. Involute: `r_b = r_p cos α`, `r_p = mz/2`, addendum `m`, dedendum `1.25m`;
flank points `x = r_b(cos t + t sin t), y = r_b(sin t − t cos t)`, mirrored about the tooth centre
with a pitch-circle half-thickness of `π/(2z)` rad; root arc between teeth (no fillet — a laser
gear). Outputs: SVG; STL via `extrudePolygon` with the bore as a hole. Tests: outer diameter
`m(z+2)`, `z` teeth, the pair's pitch circles tangent, STL watertight.

**6.2 `hole-patterns` — Hole Pattern** (`min_host: 3`). Bolt circle (count, PCD, start angle),
grid (nx, ny, pitch x/y), line; hole diameter from the fastener table (clearance close/normal/loose,
tap) or typed; optional outline (rectangle with corner radius, or circle) with a margin; centre
crosshairs and a dimension line. Outputs: SVG template; optional plate STL (outline minus holes,
thickness). Tests: positions on the circle, grid count, STL watertight with the right face count
parity.

**6.3 `patterns` — Surface Patterns** (`min_host: 3`). Living hinge (slot length, width, gap, row
pitch, staggered), honeycomb (cell across-flats, wall), slot grid, clipped to a panel W×H inside a
margin. SVG. Tests: every cut lies inside the margin; the hinge's slot count for a known panel.

**6.4 `test-pieces` — Test Pieces** (`min_host: 3`). Laser kerf comb (slots 0.10–0.60 mm in
0.05 steps, labelled), finger-joint fit test (tabs at −0.20…+0.20 mm offsets) — both SVG; 3D-print
tolerance test (pegs and holes at 0.10…0.50 mm clearance) and heat-set insert test block (a row of
holes bracketing each size from the fastener table) — both STL. Tests: labels match geometry,
watertight.

**6.5 `labels` — Labels** (`min_host: 3`). One label per line of a textarea (`Line 1 | Line 2 |
URL`), label W×H, sheet (A4, Letter, custom, or one label per file), margins, gap, font size, border,
optional QR from the URL column (qrcode-generator, error level M, drawn as `<rect>`s from
`isDark(r, c)` — never the library's HTML output). Output: one SVG per sheet. Tests: label count per
sheet, QR module grid for a known string, text escaping.

**6.6 `text-outline` — Text to Outline** (`min_host: 3`, `opens: [".ttf", ".otf"]`). Text set in a
font from the library (opentype.js `parse` → `getPath` → `toPathData(2)`), size in mm (font units
scaled so 1 SVG unit = 1 mm), letter spacing, multiple lines, alignment. Output: SVG paths for a
laser or CNC. Tests: a glyph from a small test font yields a non-empty path; sizing maps cap height
correctly. *If the jspm build of opentype.js or its two dependencies do not run as plain ESM, this
tool is dropped from the program and said so in the PR.*

**6.7 `parts` — Simple Parts** (`min_host: 3`). Spacer/standoff (round or hex, OD, ID, height),
washer, tube/bushing, plate with corner holes (W, D, T, hole, inset). STL. Tests: watertight; volume
within 1% of the analytical value.

**6.8 `lithophane` — Lithophane** (`min_host: 3`, `opens: image extensions`). Image → greyscale →
resampled to a grid whose pixel count is capped so the STL stays under 3,500,000 bytes (≈70,000
triangles) → `heightmapSolid` with `z = tMin + (1 − luminance)(tMax − tMin)` (invert optional), a
frame of `tMax` around. Width in mm, min/max thickness, resolution. The image is decoded on a canvas
from the bytes (`files.read` or a local file). Preview: the greyscale and the 3D render. Tests (on a
synthetic 4×4 grid): vertex count, bounds, watertight, darker is thicker.

**6.9 `gridfinity` — Gridfinity Bins** (`min_host: 3`). Bins (x, y in 42 mm units; height in 7 mm
units; stacking lip on/off; wall 1.2 mm; optional dividers nx×ny as overlapping shells) and
baseplates (x, y). Profile constants, named in `gridfinity_core.js`: pitch 42; footprint
`42n − 0.5`; base from the bottom 0.8 mm at 45°, 1.8 mm vertical, 2.15 mm at 45° (4.75 total); top
corner radius 3.75 shrinking with each chamfer; lip 0.7 / 1.8 / 1.9 (4.4 total) above the wall top at
`7z`. A bin is one closed shell: outer loft up, lip rings, inner loft down, floor. A baseplate is a
pocketed plate (top face with rounded-square holes via earcut, each pocket's socket loft down, a
floor). **Compatible by the spec's numbers; not printed and fitted in this work** — the PR says so.
Tests: footprint and height of a 2×1×3 bin, watertight for bins with and without dividers, baseplate
pocket count.

**6.10 `cut-list` — Cut List** (`min_host: 3`). Two modes. Lengths: parts (length × qty) from stock
lengths (length × qty or unlimited) with a kerf, first-fit-decreasing. Sheets: parts (W × H × qty,
rotate allowed per part) on sheets (W × H) with a kerf, guillotine shelf packing by decreasing height.
Outputs: one SVG diagram per stock piece or sheet with labelled parts, and a CSV cut list; the UI says
the layout is simple, not optimal. Tests: no overlaps, every part inside its sheet, kerf respected,
waste arithmetic.

### Look inside a file (`inspect`)

**6.11 `gcode` — G-code Inspector** (`min_host: 2`, `opens: .gcode .gco .nc .tap .ngc`). Parses
lines (`;` and `(…)` comments, G0/G1/G2/G3, G90/G91, G92, M82/M83, X/Y/Z/E/F); reads slicer metadata
by pattern (Cura `;TIME:`/`;Filament used:`/`;LAYER_COUNT:`; PrusaSlicer, SuperSlicer, OrcaSlicer and
Bambu `; estimated printing time`, `; filament used [mm]/[g]`, `; layer_height`, `;LAYER_CHANGE`;
Simplify3D; Kiri:Moto) and labels any value it computed itself as "estimated from moves". Shows:
slicer, layers, height, time, filament, temperatures, bounds of extruding moves, feed range, a
settings table from `; key = value` comments. Preview: a canvas of one layer (extrusion bold, travel
faint, earlier layers ghosted) with a layer slider; CNC files (no E) show Z passes with rapids and
cuts, arcs subdivided. Optional save: `<name>-summary.md`. Tests on fixture snippets from each
slicer family.

**6.12 `mesh-info` — Model Stats and Print Cost** (`min_host: 2`, `opens: .stl .3mf .obj`). STL and
OBJ via `mesh.js`; 3MF via the host's `jszip` pin (`3D/3dmodel.model` found through `_rels/.rels`,
vertices/triangles per object, build-item transforms applied, units honoured). Stats: triangles,
bounds, volume, surface area, watertight. Cost: material table (PLA 1.24, PETG 1.27, ABS 1.04, ASA
1.07, TPU 1.21, nylon 1.14, PC 1.20 g/cm³; resin by volume) with price per kg, infill %, walls
(perimeters × line width + top/bottom), print time and printer watts × tariff, remembered per browser
in `localStorage` under try/catch. Filament length at 1.75/2.85 mm. Spool-remaining calculator
(gross − empty spool). Optional save: `<name>-cost.md`. Tests: a unit cube's volume, an ASCII and a
binary STL, an OBJ with negative indices and quads, a tiny 3MF built in the test, the cost formula.

### Calculate and look up (`reference`)

**6.13 `electronics` — Electronics Calculators** (`min_host: 1`). Tabs: resistor colour code (4/5/6
bands, both directions, with a drawn resistor), SMD codes (3- and 4-digit, R as the point, EIA-96),
nearest standard value (E6/E12/E24 listed; E48/E96/E192 computed and checked against the standard
list in the test) plus the best series/parallel pair for a target, voltage divider, LED resistor,
Ohm's law and power, capacitor codes (`104` → 100 nF), wire gauge (AWG ↔ mm², `d = 0.127·92^((36−n)/39)`
mm, resistance at 20 °C, a conservative ampacity table, round-trip voltage drop). No save.

**6.14 `shop-math` — Shop Calculators** (`min_host: 1`). Tabs: feeds and speeds (`RPM = 1000·Vc/(πD)`,
feed = RPM × flutes × chip load, a chip-load table by material and cutter class), stepper
steps/mm (belt: steps × microsteps ÷ (teeth × pitch); lead screw: ÷ lead), belt length (closed loop,
`L = 2C + π(D₁+D₂)/2 + (D₂−D₁)²/4C`, pitch diameter from teeth × pitch ÷ π, and the inverse for C),
gear ratio chain, compound miter (`bevel = asin(cos T · sin(180°/n))`, `miter = atan(sin T ·
tan(180°/n))`, tested at T = 0 → 45°/0° and T = 90° → 0°/45° for n = 4), board feet and sheet area,
shelf sag (`δ = 5wL⁴/384EI`, `I = bh³/12`, an E table for pine, oak, maple, plywood, MDF,
particleboard), a unit converter. No save.

**6.15 `fasteners` — Fastener Reference** (`min_host: 1`). Searchable tables from
`_lib/fasteners_data.js`: metric coarse and fine (pitch, tap drill, clearance close/normal/loose per
ISO 273, hex nut across-flats and height, socket-head diameter and hex key), UNC/UNF (tap drill as
number/letter/fraction and mm, clearance), heat-set insert holes (labelled *typical — check the
insert's datasheet*), washer OD/ID, countersink angles. A row expands to its full set. No save.

**6.16 `laser-settings` — Laser Settings Notebook** (`min_host: 3`). Records of machine, material,
thickness, operation (cut/engrave/score), power %, speed, passes, frequency or DPI, notes, date;
add, edit, delete, search, sort. Storage: **one saved state** named "Laser settings" whose `data`
holds the records, found through `state.list()` and revised in place on every save (`stateId`), its
file `laser-settings.csv` rewritten in the library. Tests: CSV escaping, record validation, the
"find or create" rule.

## 7. Verification

- `tinkerex-addons`: `bin/test` green; `bin/rails "addons:check[…]"` from the host checkout clean
  (every entry, pin and symlinked import resolves inside PATH); the GPL-image guard untouched.
- A browser pass of every tool on the host dev server pointed at the worktree
  (`ADDON_SOURCE_PATH`), with a screenshot per tool in the PR: fields change the preview, Save lands a
  file that previews, "Open in …" on a file page opens the inspector on that file, a greyed sidecar
  tool is unaffected.
- `tinkerex`: bare `bin/ci` green with the three backend legs' RUN counts equal.
- Mutation checks named per task in the plan, with their actual output reported.

## 8. Out of scope, recorded

- "Open with" in the right-click file menu (the registry-on-every-row cost, §2).
- An addons accessory on OVH, which is what the demo needs to show any of this — an operator
  decision, not code.
- SVG nesting of arbitrary outlines (cut-list packs rectangles); image dithering for engraving;
  anything reading inventory or BOM (`maker:read` stays `false`).
- The three existing bundles' duplicated folder fields; they keep working as they are.
