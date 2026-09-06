# Gerber viewer interaction — pan, zoom, fit and layer toggles

> **For agentic workers:** execute per `.claude/commands/execute-plan.md`. One implementer (the
> slice is one coherent unit), one capped review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** the Gerber stage (a file page's single layer or a board, and the Fabrication panels'
boards) can be **panned, zoomed and fitted** like the 3D viewer, and a board's **layers can be
switched on and off**, with no change to what tracespace renders or how the server describes a board.

**The question this answers, recorded so it is not asked again (also `docs/roads-not-taken.md`):**
"convert the Gerbers and use the 3D model viewer?" — no. A board export is a 2D artefact: the fab
house reads exactly what tracespace draws, and the file page's job is to show that faithfully at any
zoom. There is no permissively licensed Gerber→mesh pipeline; extruding copper and mask polygons into
meshes needs booleans and produces hundreds of thousands of triangles for an ordinary four-layer
board, and it would still be a picture of the same 2D layers with worse fidelity. What the maker
asked for is the INTERACTION the 3D viewer has — move around and zoom — and that is a viewBox, which
`measure_controller.js` already drives for the Measure view. Share that; add layer toggles, which a
board viewer wants and a 3D conversion could not offer.

**Architecture:**
- **One viewBox pan/zoom implementation**, extracted from `measure_controller.js` into
  `app/javascript/lib/svg_pan_zoom.js` and used by BOTH controllers (§14d's "a verb more than one
  controller performs gets a named service", the JS way). Wheel zooms about the cursor, drag pans
  (pointer capture, a screen-pixel slop so a click is still a click), two-pointer pinch zooms, `Fit`
  returns to `home`. Measure keeps its own hit-test/hover/click code untouched and only delegates
  the viewBox maths and event wiring it had.
- **Layer toggles re-compose from the ONE render.** `gerber_controller.js` already holds the
  `renderLayers` result; `renderBoard` accepts a filtered `layers` list (probed against the vendored
  bundle: filtering out silkscreen re-composes both sides correctly), so toggling a layer never
  re-fetches or re-plots, it recomposes and re-serialises. The current viewBox survives a toggle and a
  Top/Bottom switch.
- **The toolbar is built by the controller**, not by three templates: a `Fit` button and one toggle
  button per layer type+side, using the existing `.btn small` / `.active` component (no new component
  selector — `docs/invariants/design-system.md` rule 3; the side buttons already use this shape).
- The server's contract (`data-gerber-layers-value`, `single`, the archive entry) is unchanged.

**Tech:** no new dependency. Pointer Events (Chrome, Safari 13+, Firefox 59+) for pan and pinch.

---

## Task A — the whole slice

**Files:**
- Create: `app/javascript/lib/svg_pan_zoom.js`
- Modify: `app/javascript/controllers/gerber_controller.js`, `app/javascript/controllers/measure_controller.js`
  (delegate to the lib; behaviour identical), `app/assets/stylesheets/pages/preview.css` (the toolbar
  row, the grab cursor; page-sheet rules qualified under `.gerber-stage` — read
  `docs/invariants/design-system.md` first), `test/system/gerber_test.rb`,
  `docs/invariants/files-preview.md` (the `:gerber` section — **use the Edit tool on this file, never
  a whole-file rewrite: a sibling implementer is editing its `:model3d` section at the same time**),
  `docs/roads-not-taken.md` (one entry: Gerber→3D conversion, considered → rejected → the interaction).

### A.1 `app/javascript/lib/svg_pan_zoom.js`

- [ ] Extract from `measure_controller.js` (its `zoom`, `startPan`, `movePan`, `endPan`,
  `toUserSpace`, `setViewBox`, the `PAN_SLOP_PX` constant and the letterbox maths) into one module:

```js
// ONE viewBox PAN/ZOOM FOR EVERY SVG STAGE — the Measure view's, extracted so the Gerber stage
// could have the same hands without a second copy of the maths (§14d). Wheel zooms about the
// cursor, a drag pans, two pointers pinch, `reset()` returns to `home`.
//
// EVERYTHING IS IN THE SVG'S OWN USER UNITS, converted from screen pixels through the element's
// letterbox: `preserveAspectRatio="xMidYMid meet"` scales by the SMALLER axis ratio and centres the
// other, and ignoring that makes the cursor drift on a non-square drawing (measure_controller.js
// learned this first). The pan SLOP is screen pixels, not user units: zoomed in, one mm is many
// pixels, so a user-space threshold calls an ordinary click a drag and swallows a selection.
//
// `home` is the fit viewBox, `[x, y, w, h]`. Zoom is bounded to [span/500, span*4] of the larger
// home dimension, so nobody zooms into a single trace's pixel or out to a dot.
const PAN_SLOP_PX = 4
const ZOOM_STEP = 1.15

export function installPanZoom(svg, { home, onChange = null } = {}) {
  let view = null
  let panOrigin = null, panScreen = null, didPan = false
  const pointers = new Map()   // pointerId -> { x, y } in screen px, for pinch
  let pinchStart = null        // { dist, view, centre } at the moment the second finger landed

  const span = () => Math.max(home[2], home[3])

  function setViewBox([x, y, w, h]) {
    view = [x, y, w, h]
    svg.setAttribute("viewBox", `${x} ${y} ${w} ${h}`)
    onChange?.(view)
  }

  // Screen px -> user units (see the header for why the letterbox is part of this).
  function toUserSpace(clientX, clientY) {
    const rect = svg.getBoundingClientRect()
    const [x, y, w, h] = view
    const scale = Math.min(rect.width / w, rect.height / h)
    const offX = (rect.width - w * scale) / 2
    const offY = (rect.height - h * scale) / 2
    return { x: x + (clientX - rect.left - offX) / scale, y: y + (clientY - rect.top - offY) / scale }
  }

  function zoomAbout(px, py, factor) {
    const [x, y, w, h] = view
    const nextW = Math.min(Math.max(w * factor, span() / 500), span() * 4)
    const nextH = h * (nextW / w)
    setViewBox([px - (px - x) * (nextW / w), py - (py - y) * (nextH / h), nextW, nextH])
  }

  function onWheel(event) {
    event.preventDefault()
    const p = toUserSpace(event.clientX, event.clientY)
    zoomAbout(p.x, p.y, event.deltaY > 0 ? ZOOM_STEP : 1 / ZOOM_STEP)
  }

  function onPointerDown(event) {
    if (event.button !== 0 && event.pointerType === "mouse") return
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY })
    svg.setPointerCapture(event.pointerId)
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()]
      pinchStart = { dist: Math.hypot(a.x - b.x, a.y - b.y), view: [...view],
                     centre: toUserSpace((a.x + b.x) / 2, (a.y + b.y) / 2) }
      panOrigin = null
      return
    }
    panOrigin = toUserSpace(event.clientX, event.clientY)
    panScreen = { x: event.clientX, y: event.clientY }
    didPan = false
    svg.classList.add("is-panning")
  }

  function onPointerMove(event) {
    if (!pointers.has(event.pointerId)) return
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY })
    if (pinchStart && pointers.size === 2) {
      const [a, b] = [...pointers.values()]
      const dist = Math.hypot(a.x - b.x, a.y - b.y)
      if (dist > 0) {
        view = [...pinchStart.view]
        zoomAbout(pinchStart.centre.x, pinchStart.centre.y, pinchStart.dist / dist)
      }
      return
    }
    if (!panOrigin) return
    if (Math.hypot(event.clientX - panScreen.x, event.clientY - panScreen.y) > PAN_SLOP_PX) didPan = true
    const p = toUserSpace(event.clientX, event.clientY)
    const [x, y, w, h] = view
    setViewBox([x + (panOrigin.x - p.x), y + (panOrigin.y - p.y), w, h])
  }

  function onPointerUp(event) {
    pointers.delete(event.pointerId)
    svg.releasePointerCapture?.(event.pointerId)
    if (pointers.size < 2) pinchStart = null
    if (pointers.size === 0) { panOrigin = null; svg.classList.remove("is-panning") }
  }

  svg.addEventListener("wheel", onWheel, { passive: false })
  svg.addEventListener("pointerdown", onPointerDown)
  svg.addEventListener("pointermove", onPointerMove)
  svg.addEventListener("pointerup", onPointerUp)
  svg.addEventListener("pointercancel", onPointerUp)
  setViewBox(home)

  return {
    reset: () => setViewBox(home),
    view: () => [...view],
    set: (next) => setViewBox(next),
    didPan: () => didPan,
    toUserSpace: (event) => toUserSpace(event.clientX, event.clientY),
    destroy() {
      svg.removeEventListener("wheel", onWheel)
      svg.removeEventListener("pointerdown", onPointerDown)
      svg.removeEventListener("pointermove", onPointerMove)
      svg.removeEventListener("pointerup", onPointerUp)
      svg.removeEventListener("pointercancel", onPointerUp)
    }
  }
}
```

- [ ] Wire it in the importmap the way `lib/chunk_upload` is (`pin "lib/svg_pan_zoom", to: "lib/svg_pan_zoom.js"`
  — check `config/importmap.rb`: if `pin_all_from "app/javascript/lib"` already covers it, nothing to add;
  `test/integration/web/lazy_bundles_test.rb` must stay green).

### A.2 `measure_controller.js` delegates

- [ ] Replace its `zoom`/`startPan`/`movePan`/`endPan`/`toUserSpace`/`setViewBox` bodies with the
  lib: on build, `this.panZoom = installPanZoom(svg, { home: this.home, onChange: (v) => { this.view = v } })`;
  `reset()` calls `this.panZoom.reset()` + `clearMarks()`; the click handler's "was this a drag?"
  check reads `this.panZoom.didPan()`; `toUserSpace` callers (hover) use `this.panZoom.toUserSpace(e)`.
  Remove the now-dead event listeners it added itself (`wheel`, `pointerdown`, `pointermove` for pan)
  — keep its hover `pointermove` and click/mouse handlers exactly as they are (the header of that
  file explains their ordering; do not reorder). `this.view`/`this.home` keep their meaning because
  other methods read them.
- [ ] Run `bin/rails test test/system/lbrn_measure_test.rb test/system/*measure*` green. Nothing there
  pins wheel/drag, so ALSO mutation-check through the Gerber tests below (M1) and state in the PR
  that Measure's pan/zoom is covered only transitively.

### A.3 `gerber_controller.js` — hands and layer toggles

- [ ] Keep `rendered` (the `renderLayers` result) on `this`. Build the toolbar once, before the first
  `show()`, as the first child of the stage container (a `<div class="gerber-tools">`): a `Fit`
  button (`.btn small`, `data-action="gerber#fit"`) and, for a stackup (not `single`), one toggle
  `.btn small active` per layer, labelled from `layer.type` + `layer.side` ("top copper", "bottom
  silkscreen", "drill", "outline" — reuse the wording `FilesHelper::GERBER_LAYER_LABELS` uses, written
  once in the controller as a small map from tracespace's `type`), `aria-pressed="true"`,
  `data-action="gerber#toggleLayer"`, `data-gerber-layer-id="<layer.id>"`.
- [ ] `show(side)` keeps doing what it does, then: read the injected SVG's own `viewBox` as `home` the
  FIRST time (both sides share it — tracespace composes them on one viewBox), install the lib on the
  new SVG, and if a previous view exists (`this.view`), `set(this.view)` so a Top/Bottom switch and a
  layer toggle do not snap back to the fit. Destroy the previous handle before replacing the SVG.
- [ ] `toggleLayer(event)`: flip `aria-pressed`/`.active`, keep a `Set` of hidden layer ids, then
  `this.sides = compose(this.rendered, hidden)` where `compose` calls
  `ts.renderBoard({ ...rendered, layers: rendered.layers.filter((l) => !hidden.has(l.id)) })` and
  `stringifySvg` both sides — hold `ts` on `this` after the import. Hiding EVERY layer renders an empty
  board; that is allowed (the toggles say so). `fit()` → `this.panZoom.reset()`.
- [ ] Single-layer mode: the toolbar has only `Fit`; pan/zoom installed the same way.
- [ ] Update the header comment's SINGLE-vs-STACKUP paragraph with one sentence on the toolbar and the
  shared lib; do NOT touch the "ON S3 THE FETCH BELOW" paragraph or `filesFor`.

### A.4 CSS (`pages/preview.css`, inside `.gerber-stage` only)

- [ ] `.gerber-stage .gerber-tools { display: flex; flex-wrap: wrap; gap: 6px; margin: 0; }`,
  `.gerber-stage svg { cursor: grab; touch-action: none; }`, `.gerber-stage svg.is-panning { cursor: grabbing; }`.
  `touch-action: none` is what lets Pointer Events see a second finger instead of the browser
  scrolling the page. Run `bin/rails test test/css_hygiene_test.rb`.

### A.5 Tests — `test/system/gerber_test.rb`

- [ ] Helpers: `view_box(selector)` → `page.evaluate_script("document.querySelector('#{selector} svg').getAttribute('viewBox')").split.map(&:to_f)`;
  a `wheel_on(selector, delta_y:)` that dispatches a `WheelEvent` at the element's centre via
  `execute_script` (Capybara's driver has no wheel action; a synthetic `new WheelEvent("wheel", { deltaY, clientX, clientY, bubbles: true, cancelable: true })`
  dispatched on the svg is what the listener sees); a `drag_on(selector, dx:, dy:)` that dispatches
  `pointerdown`/`pointermove`/`pointerup` PointerEvents (`pointerId: 1, button: 0, isPrimary: true`)
  from the centre.
- [ ] Cases on a board page (the `.gbrjob` page or the zipped export, either already fixtured here):
  1. wheel with `deltaY: -100` → the viewBox WIDTH shrinks (zoom in), and the viewBox's centre stays
     under the cursor (assert the point under the centre maps to the same user coordinate, or simply
     that width shrank and `x` grew — the narrowest true thing);
  2. `drag_on(dx: 80, dy: 0)` → viewBox `x` decreases (content moved right), width unchanged;
  3. `Fit` → the viewBox equals the home viewBox again (compare to the one read right after `ready`);
  4. a layer toggle: count `svg path` before, click the "top silkscreen" (or the fixture's `.gtl` →
     "top copper") toggle, count after → fewer paths, `aria-pressed="false"`, and the viewBox is
     unchanged by the toggle (it was zoomed first);
  5. the single-layer page has a `Fit` button and no layer toggles.
- [ ] **MUTATIONS (run for real, output in the PR, then `git checkout -- <file>`):**
  - M1 `svg_pan_zoom.js`: `zoomAbout` uses `factor = 1` (no zoom) → case 1 red (and this is the only
    pin Measure's zoom has — say so).
  - M2 `gerber_controller.js`: `compose` ignores `hidden` → case 4's path count red.
  - M3 `fit()` does nothing → case 3 red.
  - M4 `onPointerMove` never sets the viewBox → case 2 red.

### A.6 Docs

- [ ] `docs/invariants/files-preview.md`, in the `:gerber` section (Edit tool only): one paragraph —
  the stage's pan/zoom/fit is `lib/svg_pan_zoom.js`, SHARED with Measure (never a second copy);
  layer toggles re-compose from the one `renderLayers` result and never re-fetch; the toolbar is
  controller-built so the three templates cannot drift; the 3D-conversion question and why it was
  refused (point at roads-not-taken).
- [ ] `docs/roads-not-taken.md`: an entry "Gerber → 3D via the model viewer" — considered on
  2026-09-06 → rejected (no permissive Gerber→mesh pipeline; a board is 2D; fidelity and triangle
  count) → current approach (tracespace SVG + shared viewBox interaction + layer toggles).
- [ ] Sweep: `grep -rn "pan\|zoom" app/javascript/controllers/measure_controller.js` for comments that
  describe code now living in the lib and point them there.

## Self-review

- Spec coverage: pan/zoom/pinch/fit (A.1, A.3), layer toggles (A.3), shared implementation (A.2),
  CSS (A.4), tests + mutations (A.5), docs incl. the rejected 3D route (A.6).
- Type consistency: `home`/`view` are `[x, y, w, h]` arrays everywhere; `installPanZoom` returns the
  handle `gerber_controller.js` calls `reset`/`set`/`view`/`destroy` on and Measure calls
  `reset`/`didPan`/`toUserSpace` on.
- The server contract is untouched; the request tests in `gerber_preview_test.rb` must stay green
  unmodified.
