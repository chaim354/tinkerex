# Maker.js generator harness + Material Test Grid — design

**Date:** 2026-07-22
**Status:** design (approved for planning)
**Topic:** the first **client-only** `/tools` addon — a browser-side **generator harness** built on
Maker.js (Apache-2.0), shipping with the **Material Test Grid** as its first generator. Proves the
client half of the addon framework (only the boxes.py *sidecar* addon has shipped so far) and turns a
whole family of 2D laser/CNC generators into "one harness, many JS modules."

Framework reference: `docs/superpowers/specs/2026-07-20-addon-framework-boxes-design.md`
(Registry + `AddonState`/`AddonFile` + `Maker::Addons::LibraryOutput`). Menu it comes from:
`docs/addon-backlog.md` (Phase 1, item 1).

---

## 1. Goal & scope

Add a **client-only** addon at `/tools/generators` where parametric 2D drawings are generated **in the
browser** with Maker.js, previewed live, and saved into the file library as a tied bundle (the SVG *and*
the parameters that made it). Ship the **harness** and its **first generator** (Material Test Grid)
together, structured so every future generator (kerf cards, bolt-circle, living-hinge, badge maker…) is
**a single self-contained JS module + one JS registry line — no Ruby change**.

**The core design decision (approved):** the Rails side stays **generator-agnostic addon plumbing**;
**all generator specifics live in JS.** This is what makes the harness leverage real and proves the
framework spans client-only tools (§10 of the framework spec designed *for* this; it is now the first
consumer).

**In scope:**
- Vendoring **Maker.js** (browser standalone build, importmap-pinned) — the same pattern JSZip uses.
- A **harness** Stimulus controller: a generic form-builder (renders fields from a module's param
  schema), a **live Maker.js SVG preview**, and a **save** action.
- A **JS generator registry** + the first module, `material_test_grid.js`.
- One thin, **generator-agnostic** `Tools::GeneratorsController` (`index`/`create`/`show`) that persists
  `AddonState` and writes the `[svg, params.json]` bundle via the existing `LibraryOutput` — **no new
  server infrastructure**.
- One `Maker::Addons::Registry` line (key `generators`, always available).

**Explicitly out of scope (this pass):**
- **Any second generator** (kerf card, bolt-circle, etc.). The harness is built *for* them; they land
  later as JS modules. The DoD proves adding one is a JS module + a registry line.
- **Color-coded laser layers** for the test grid (each cell a distinct LightBurn layer→setting). v1 is a
  **simple labeled grid** (universal, no laser-software assumptions). Noted as a future param.
- **In-place re-versioning of a saved bundle** (edit → new versions of the same nodes). v1 mirrors the
  shipped boxes addon: **each save creates a new `AddonState` + bundle**; reopen = "duplicate & tweak"
  prefill. `LibraryOutput`'s regenerate-in-place capability (framework spec §5) stays available for a
  later enhancement.
- **DXF output.** Maker.js exports DXF client-side (`makerjs.exporter.toDXF`), so it is a near-free
  future add (another entry in the files array). v1 output is **SVG + params.json**.
- Any change to the sync engine, changelog, conflicts, locks, or mounts (framework spec §10 tripwire
  holds — this addon writes through the existing `FileLayer` port via `LibraryOutput`, nothing deeper).
- A generic client-facing `AddonState` JSON CRUD API. **Not needed here** — a server-rendered controller
  (the boxes pattern) covers discrete save/reopen. A future autosave-style client addon (notes) can add
  it then.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Rails app (permissive) — NO sidecar, NO GPL, NO new deploy surface     │
│                                                                         │
│  Maker::Addons::Registry   "generators" (available: -> { true })        │
│  Tools::GeneratorsController  (generator-AGNOSTIC)                       │
│    index  → saved grids (AddonState "generators") + mounts the harness   │
│    create → AddonState.create + LibraryOutput.write([svg, params.json])  │
│    show   → reopen a saved grid (prefill → tweak → save-new)             │
│                                                                         │
│  ── reused verbatim ──────────────────────────────────────────────────  │
│  Maker::Addons::LibraryOutput · Maker::AddonState/AddonFile ·           │
│  Tools::BaseController auth · folder picker · Maker::Previews (SVG thumb) │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │  server-rendered + Stimulus
                                ▼
  app/javascript/controllers/generator_controller.js  (the harness)
    ├─ vendored Maker.js (Apache-2.0, importmap-pinned like JSZip)
    ├─ generic form-builder  (fields ← module.params schema)
    ├─ live preview          (makerjs.exporter.toSVG → inline SVG, on input)
    └─ save                  (POST svg Blob + params JSON → create)
  app/javascript/generators/index.js         (JS registry: key → module)
  app/javascript/generators/material_test_grid.js   (the first module)
```

**Units, each independently understandable/testable:**
- **`Tools::GeneratorsController`** — generic addon CRUD. Knows *nothing* about any generator; it persists
  a state and writes a two-file bundle. (§6)
- **`generator_controller.js`** (harness) — form-builder + preview + save. Knows the *contract*, not any
  specific generator. (§4)
- **A generator module** — `{ key, title, description, params, generate(values) }`. Pure geometry +
  declarative schema. (§4)
- **`material_test_grid.js`** — the first generator module. (§5)

---

## 3. JS delivery — vendoring Maker.js (importmap + Propshaft)

This app has **no bundler**: `importmap-rails` + `propshaft`, libraries vendored under
`vendor/javascript` and pinned in `config/importmap.rb` (see JSZip, which was vendored precisely because
pinning it raw dragged transitive Node polyfills).

- Maker.js (`makerjs`, **Apache-2.0** — permissive ✓, §9) has runtime dependencies, so **pin the raw
  package and it drags transitive deps** — the JSZip failure mode.
- **Mitigation:** vendor Maker.js's **browser standalone build** (`dist/browser.maker.js`, deps inlined
  into one UMD file) into `vendor/javascript/makerjs.js`, and `pin "makerjs", to: "makerjs.js"` so
  `import makerjs from "makerjs"` resolves. Bytes untouched; only the specifier is bare (the JSZip
  approach verbatim).
- **First implementation task:** confirm the exact standalone build path/version and that the UMD build
  exposes a module usable under importmap (fall back to a small ESM shim if the UMD only attaches to
  `window`, mirroring how the JSZip dist was made importable).

---

## 4. The harness + the generator contract

**A generator module** (one JS file, self-contained — schema *and* geometry live together):

```js
export default {
  key: "material-test-grid",
  title: "Material Test Grid",
  description: "Power × speed sweep for dialing in laser settings.",
  params: [
    { name: "cols",     label: "Speed steps",   type: "int",   default: 5,  min: 1, max: 20 },
    { name: "rows",     label: "Power steps",   type: "int",   default: 5,  min: 1, max: 20 },
    { name: "speedMin", label: "Speed min",     type: "float", default: 100 },
    { name: "speedMax", label: "Speed max",     type: "float", default: 500 },
    { name: "powerMin", label: "Power min (%)", type: "float", default: 10 },
    { name: "powerMax", label: "Power max (%)", type: "float", default: 100 },
    { name: "cell",     label: "Cell size (mm)",type: "float", default: 10 },
    { name: "gap",      label: "Gap (mm)",      type: "float", default: 4 },
    { name: "material", label: "Material label",type: "text",  default: "" },
    { name: "labels",   label: "Cell labels",   type: "bool",  default: true },
  ],
  // Pure: values -> a Maker.js model. No DOM, no I/O. Testable + previewable identically.
  generate(v) { /* build the grid model (see §5) */ return model; },
};
```

**The harness** (`generator_controller.js`, one Stimulus controller for the whole family):
1. Resolves the active generator module by key (from the picker, or a saved state's `generator`).
2. **Builds the form** generically from `module.params` (a field per entry, by `type`:
   number/text/checkbox, with `default`/`min`/`max`/`label`).
3. On any input: `model = module.generate(values); svg = makerjs.exporter.toSVG(model)` → renders the SVG
   **inline** into the preview pane. Cheap, instant, no server round-trip.
4. On **Save**: exports the current SVG to a `Blob`, and POSTs a multipart form
   `{ name, generator, params(JSON), svg(Blob), parent_node_id }` to `create`.

**Contract boundary:** the harness knows `{ key, title, description, params, generate }` and nothing
else; a module knows geometry + schema and nothing about the DOM, Rails, or saving. **Adding a
generator = author one module + add it to the JS registry (`generators/index.js`). No Ruby, no new
controller, no route.** That is the whole point.

**The picker + gallery are client-rendered** from the JS registry (the tool requires JS anyway for
Maker.js), so Rails holds **zero** per-generator knowledge — reinforcing the agnostic controller.

---

## 5. Material Test Grid — v1 geometry

A `rows × cols` grid of squares laid out in mm:
- **X axis = speed** sweep (`speedMin`→`speedMax` across `cols`), **Y axis = power** sweep
  (`powerMin`→`powerMax` across `rows`), linearly interpolated per step.
- Each square is `cell` mm, separated by `gap` mm.
- When `labels` is on, each cell carries a small `S<speed> P<power>` text label (an SVG `<text>` node),
  plus **axis labels** ("Speed →", "Power ↓") and a **title block** with the `material` text.
- Units are mm; the SVG is sized to the real grid extent so it imports at true scale into laser software.
- **v1 is a plain labeled grid** — the maker assigns the per-row/column settings in their laser software.
  No color-coded layers (the future param), no per-cell layer conventions.

`generate` is a **pure function** (`values → Maker.js model`) so it previews and (optionally) unit-tests
identically. The only user-supplied string is `material`, which becomes an SVG `<text>` value — escaped
by SVG text-node semantics; the harness never `innerHTML`-injects raw user text.

**Bounds:** the harness caps `rows`/`cols` at 20 (schema `max`) and validates numeric ranges before
generating, so a pathological config cannot produce a runaway SVG. The server `create` re-checks the
posted SVG's byte size against a cap (belt-and-suspenders; the generation is client-side).

---

## 6. Server side — `Tools::GeneratorsController` (generator-agnostic)

Mirrors `Tools::BoxesController`, minus the sidecar, and **without any per-generator branching**:

- **`GET /tools/generators` (`index`)** — renders the shell: the user's **saved grids**
  (`current_user.maker_addon_states.for_addon("generators")`, newest first, `includes(:files)` — no N+1,
  exactly as boxes does) + the **harness mount** (Stimulus renders the generator picker + form + preview).
- **`POST /tools/generators` (`create`)** — the generic save:
  ```ruby
  state = current_user.maker_addon_states.create!(
    addon_key: "generators",
    name: params.require(:name),
    data: { generator: params.require(:generator), params: JSON.parse(params.require(:params)) }
  )
  base = state.name.parameterize.presence || "grid"
  Maker::Addons::LibraryOutput.write(
    user: current_user, state:, parent_node_id: chosen_parent_node_id,
    files: [
      { name: "#{base}-#{state.id}.svg", bytes: svg_bytes,
        content_type: "image/svg+xml", role: "output" },
      { name: "#{base}-#{state.id}.params.json",
        bytes: JSON.pretty_generate(state.data), content_type: "application/json", role: "parameters" },
    ]
  )
  ```
  `svg_bytes` comes from the posted `svg` part. The controller **never inspects the SVG** beyond a
  size-cap guard and a light "is this SVG" content check (leading `<svg`/`<?xml`), consistent with the
  fact the user could upload any SVG through the existing uploader anyway.
- **`GET /tools/generators/:id` (`show`)** — loads the saved `AddonState`, renders its library bundle
  (the SVG thumbnail + the params file) and serializes `data` into a data attribute so the harness can
  **rehydrate the form and re-preview** ("duplicate & tweak" → Save creates a new state, matching boxes).

**Reused verbatim (kept DRY):** `chosen_parent_node_id` + `folder_options` are **extracted from
`BoxesController` into a shared `Tools::LibraryFolders` concern** and included by both — no duplication.
Everything else (`AddonState`/`AddonFile`, `LibraryOutput`, `BaseController` auth + user-scoping, the
`Maker::Previews` SVG thumbnailer via `LibraryOutput`'s `enqueue_preview`) is used as-is.

**Registry (one line):**
```ruby
"generators" => Addon.new(
  key: "generators", title: "Generators", icon: "✏️",
  description: "Parametric 2D drawings → SVG (laser & CNC)",
  available: -> { true }   # client-only — always available; demonstrates a no-sidecar addon
)
```

**Routes:** add under the existing `tools` scope: `resources :generators, only: %i[index create show]`.

---

## 7. Security & ops

- **No sidecar, no external calls, no new secrets.** Generation is pure client JS; the server only
  persists and writes to the library it already owns.
- **Inline preview SVG is our own output**, built from Maker.js primitives; the sole user string
  (`material`) is an SVG text value, not markup. The harness sets it via DOM text APIs / Maker.js, never
  `innerHTML`. So inlining the preview is safe (unlike the boxes sidecar's output, which is rasterized to
  PNG because it is treated as untrusted; here there is no untrusted producer).
- **Saved `.svg`** is served through the library's existing blob path, which already forces SVG to
  **download** (no inline serving of stored SVG) — unchanged.
- **Resource bounds** — schema caps (≤20×20) + numeric-range validation client-side, plus a server-side
  posted-SVG **size cap** returning `422` with a clear message. No unbounded generation, no hung request.
- **§15 (bytes out of Rails):** the saved SVG + params are small **generated outputs**, written
  server-side through `LibraryOutput` exactly as the boxes addon writes its output — the same, accepted
  posture. §15 targets large *client uploads*; there is no such upload here.

---

## 8. Testing

- **`Tools::GeneratorsController`** (the gate) — `index` (lists the user's saved grids, greys nothing —
  always available), `create` (posts a fixture SVG + params → asserts one `AddonState` with the right
  `data`, a tied **`AddonFile` bundle**: an `output` SVG node *and* a `parameters` JSON node under one
  per-save folder, and a **preview enqueued** per node), `show` (reopen renders the bundle + serializes
  `data`). Uses a **fixture SVG string** — **no Maker.js in Ruby**, exactly how boxes tests use a stubbed
  client rather than a live sidecar.
- **All three backends** — the suite runs green on `bin/rails test`, `LIBRARY_BACKEND=share`, and
  `LIBRARY_BACKEND=s3` (`LibraryOutput` is already contract-tested across backends; these tests assert
  the addon wiring on each).
- **Shared concern** — a small test that `Tools::LibraryFolders` scopes folder options to the user's own
  live dirs (moved with the extraction; boxes already relied on this behavior).
- **Registry/gallery** — `/tools` lists "Generators" and it is **not** greyed (always available),
  covering the always-on client-addon path the boxes tests don't.
- **Generator geometry** — `generate()` is a pure function. This importmap app has **no JS test runner**,
  so v1 covers it by (a) keeping `generate` pure and small and (b) a **documented manual browser smoke**
  (pick Material Test Grid → adjust params → see the grid update → Save → find the SVG+params bundle in
  the library with a thumbnail). Adding a JS test runner is out of scope; if one is later added, `generate`
  is ready to unit-test unchanged.

---

## 9. Deferred / out of scope

- Any **second generator** (kerf/focus card, bolt-circle→DXF, living-hinge, inlay, badge/tag) — each a
  future JS module; the harness exists to make them trivial.
- **DXF export** (`makerjs.exporter.toDXF`) — a near-free future file in the bundle.
- **Color-coded laser layers** for the test grid (LightBurn layer→setting per cell).
- **In-place bundle re-versioning** on edit (v1 = save-new, per shipped boxes).
- A **client-facing `AddonState` JSON API** (a future autosave-style addon adds it).
- A **JS test runner** for pure generator functions.

## 10. Definition of done

- `/tools` shows a **"Generators"** tile (always available), opening `/tools/generators`.
- A user can: open the tool → the **Material Test Grid** form renders from its JS schema → adjust params
  → see the grid **preview live** (in-browser Maker.js) → **Save** → find the **bundle** in their library
  (`grid.svg` with a thumbnail *and* `grid.params.json`, grouped in one folder) → **reopen** a saved grid
  and tweak → Save (a new state + bundle).
- **Maker.js is vendored + importmap-pinned** (Apache-2.0 isolated to a static asset), no bundler, no
  sidecar, no new deploy surface.
- The **server controller is generator-agnostic** — demonstrably: it contains no reference to
  "material-test-grid" or grid geometry; all generator knowledge is in JS.
- **Adding a second generator is demonstrably a JS module + one JS registry line** — no Ruby, no route,
  no controller change (shown by the harness/registry structure, even though no second generator ships).
- Server suite green on `bin/rails test`, `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`.
