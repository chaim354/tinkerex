import { Controller } from "@hotwired/stimulus"
import { installPanZoom } from "lib/svg_pan_zoom"

// ONE GERBER LAYER, OR A WHOLE BOARD, rendered in the browser by tracespace — so this app ships no
// server-side PCB renderer and no sidecar (gerbv is GPL, CLAUDE.md §9).
//
// The module is ONE vendored build (bin/build-tracespace, importmap pin "tracespace") and it is
// imported LAZILY here, on connect, so a page without a Gerber never downloads its 98 KB — the
// KiCanvas rule, and config/importmap.rb pins it `preload: false` so the browser does not fetch it
// anyway (test/integration/web/lazy_bundles_test.rb).
//
// `layersValue` IS A SERVER-BUILT LIST OF {name, url} — OR ONE ARCHIVE ENTRY — AND THE `name` IS
// LOAD-BEARING. tracespace identifies what a layer IS — top copper, solder mask, drill — from the
// FILENAME, never from the bytes, so the name the server put in this list is what decides where the
// file lands in the stackup. That is the same property KiCanvas has (it reads the trailing
// extension off the URL it fetches), which is why both surfaces link the NAMED blob route: the
// fetch below does not depend on it, but nothing is gained by having the two disagree, and a
// download from the same URL wants the real name. An entry carrying `archive: true` is a zipped
// export and expands to several layers here — `filesFor` below, and FilesHelper#gerber_layers_for
// is where the server builds both shapes.
//
// SINGLE vs STACKUP is a SERVER decision, not a count of the layers here. A file page renders the
// one file it is about even when its folder holds a whole board (`singleValue` true → renderLayers,
// one layer, no side toggle); a project panel renders the board (`renderBoard`, top and bottom).
// THE TOOLBAR FOLLOWS FROM THAT SAME FLAG and is built HERE rather than in the three templates that
// mount this controller: a `Fit` button always, plus — for a stackup only — one show/hide toggle per
// layer, whose LABELS come from tracespace's own `type`/`side` and therefore cannot exist before the
// parse. Three server-rendered copies of a list only the browser can compute is the drift §14d
// exists to stop, and the side buttons stay in the templates precisely because they are known
// without one.
//
// PAN, ZOOM AND FIT ARE lib/svg_pan_zoom's, SHARED WITH THE MEASURE VIEW — never a second copy of
// the letterbox maths. That module was measure_controller.js's until 2026-09-06; the Gerber stage
// wanted the same hands, so it moved rather than being reimplemented (§14d).
//
// ON S3 THE FETCH BELOW LEAVES THE ORIGIN, as modelviewer_controller.js's and
// kicanvas_controller.js's do: the blob route answers a presigned redirect to the bucket, which
// the browser reads only if the bucket's CORS rule allows this origin (docs/DEPLOY.md), under a
// connect-src the port names for the CSP (FileLayer#presigned_origin). Shared by every
// client-side viewer in this app; the share and chunk_remote deployments stream from Rails and
// never leave the origin.

// tracespace's LAYER TYPE -> THE WORD THE REST OF THE APP USES. Deliberately the same vocabulary as
// FilesHelper::GERBER_LAYER_LABELS, which names the badge beside each file in the Fabrication
// panel: a toggle reading "top silk" over a row badged "top silk" is one board described once. That
// helper answers from the EXTENSION on the server, before any parse; this answers from what
// tracespace decided after it, and the two agree by using one wording rather than one source (they
// cannot share a source — one runs in Ruby before the fetch, the other in the browser after it).
const LAYER_TYPE_WORDS = {
  copper: "copper", soldermask: "mask", silkscreen: "silk", solderpaste: "paste",
  drill: "drill", outline: "outline", drawing: "drawing"
}
// `all` and anything unrecognised contribute no prefix — a drill file spans the board, so "drill"
// is the whole truth about it and "all drill" would be noise.
const LAYER_SIDE_WORDS = { top: "top", bottom: "bottom", inner: "inner" }

function layerLabel({ type, side }) {
  const word = LAYER_TYPE_WORDS[type] || type || "layer"
  const prefix = LAYER_SIDE_WORDS[side]
  return prefix ? `${prefix} ${word}` : word
}

export default class extends Controller {
  static targets = ["stage", "status", "side"]
  static values = { layers: Array, single: Boolean }

  async connect() {
    // HIDDEN LAYERS ARE IDS, NOT INDEXES, and the Set is built before the parse so `compose()` has
    // one shape to read whether or not a toggle has ever been clicked.
    this.hidden = new Set()
    this.side = "top"
    try {
      const ts = await import("tracespace")
      // FETCHED IN PARALLEL, but a single failure fails the whole board: a stackup missing its
      // outline layer renders at the wrong size and a stackup missing its drill file renders solid
      // copper over the holes, either of which is a WRONG picture rather than a partial one.
      // `.flat()` because one entry can be a whole archive — see `filesFor`.
      const files = (await Promise.all(this.layersValue.map((layer) => this.filesFor(layer)))).flat()
      // read -> plot -> renderLayers is the whole pipeline; renderBoard composes the two sides out
      // of a renderLayers result, so both branches share everything up to that point.
      //
      // THE RESULT IS KEPT, which is what makes a layer toggle free: `compose()` re-composes from
      // this object and never re-fetches, re-reads or re-plots (see its own comment).
      this.ts = ts
      this.rendered = ts.renderLayers(ts.plot(await ts.read(files)))
      this.compose()
      this.buildTools()
      this.show("top")
      // The status line is a SIBLING of the stage, so replacing the stage's children never touches
      // it — kicanvas_controller.js records the same trap: without this, "Loading the viewer…" sits
      // above a working render forever.
      if (this.hasStatusTarget) this.statusTarget.remove()
      this.element.dataset.gerberState = "ready"
    } catch (e) {
      this.element.dataset.gerberState = "failed"
      if (this.hasStatusTarget) this.statusTarget.textContent = "The viewer could not load."
    }
  }

  disconnect() {
    this.panZoom?.destroy()
    this.panZoom = null
  }

  // ONE LAYER ENTRY IS EITHER A FILE OR A WHOLE ARCHIVE. A loose layer is fetched and named as it
  // always was. An entry with `archive: true` is a zipped export: the zip is fetched ONCE through
  // the same URL a download uses, opened HERE with JSZip — never by Rails (§15; Maker::GerberArchive's
  // header has the argument) — and each member the server named is handed to tracespace as a File
  // named by its BASENAME, because that is what tracespace identifies a layer from and what the
  // server matched the job file against. A member the zip does not hold fails the whole board, the
  // rule the fetch above already applies to a missing layer: a stackup rendered without its outline
  // or its drills is a wrong picture, not a partial one.
  //
  // `new File([text], name)` rather than the Response's own blob: tracespace's `read()` branches on
  // its argument — a STRING is a filesystem path it would try to open through node:fs — so it has
  // to be a File, and a File carries the name the parser keys on.
  //
  // `import("jszip")` IS LAZY for the same reason tracespace's is: the pin is preloaded for
  // bundle_controller.js's static import, but a Gerber page without a zip never runs this.
  async filesFor({ name, url, archive, members }) {
    const res = await fetch(url)
    if (!res.ok) throw new Error(`${name}: ${res.status}`)
    if (!archive) return [new File([await res.text()], name)]

    const { default: JSZip } = await import("jszip")
    const zip = await JSZip.loadAsync(await res.arrayBuffer())
    return Promise.all(
      members.map(async (path) => {
        const entry = zip.file(path)
        if (!entry) throw new Error(`${name}: ${path} is not in the archive`)
        return new File([await entry.async("string")], path.split("/").pop())
      })
    )
  }

  top() { this.show("top") }
  bottom() { this.show("bottom") }

  fit() { this.panZoom?.reset() }

  // A TOGGLE RE-COMPOSES; IT NEVER RE-FETCHES AND NEVER RE-PLOTS. `renderBoard` takes a
  // renderLayers result and its `layers` list is what it splits by side, so handing it a FILTERED
  // list composes the same board minus those layers — probed against the vendored bundle with a
  // real Fusion export, not assumed. Everything expensive (the fetch, the parse, the plot, the
  // per-layer render) already happened in `connect` and is reused.
  //
  // HIDING EVERY LAYER RENDERS AN EMPTY BOARD, and that is allowed: the toggles say so, and the
  // way back is the same click. Refusing the last one would be a rule nothing in the UI states.
  toggleLayer(event) {
    const button = event.currentTarget
    const id = button.dataset.gerberLayerId
    if (this.hidden.has(id)) this.hidden.delete(id)
    else this.hidden.add(id)

    const shown = !this.hidden.has(id)
    button.classList.toggle("active", shown)
    button.setAttribute("aria-pressed", String(shown))

    this.compose()
    this.show(this.side)
  }

  // THE ONE PLACE `this.sides` IS BUILT, for both the single and the stackup branch — so the
  // toggle path and the first render can never disagree about what a side is. `stringifySvg`
  // serialises the hast tree the renderer built; nothing of the Gerber's own text reaches the DOM.
  compose() {
    const { ts, rendered } = this
    if (this.singleValue) {
      this.sides = { top: ts.stringifySvg(rendered.rendersById[rendered.layers[0].id]) }
      return
    }
    const layers = rendered.layers.filter((layer) => !this.hidden.has(layer.id))
    const board = ts.renderBoard({ ...rendered, layers })
    this.sides = { top: ts.stringifySvg(board.top), bottom: ts.stringifySvg(board.bottom) }
  }

  // BUILT ONCE, BEFORE THE FIRST `show()`, and prepended to the stage container so it survives
  // every `show()` — which replaces the stage TARGET's children, one level down.
  //
  // A SINGLE LAYER GETS `Fit` AND NOTHING ELSE: there is one layer, so a toggle for it is a button
  // whose only effect is to blank the page, and `renderLayers` has no stackup to re-compose.
  buildTools() {
    const tools = document.createElement("div")
    tools.className = "gerber-tools"
    tools.appendChild(this.toolButton("Fit", { gerberAction: "fit" }))
    if (!this.singleValue) {
      for (const layer of this.rendered.layers) {
        const button = this.toolButton(layerLabel(layer), { gerberAction: "toggleLayer", layerId: layer.id })
        button.classList.add("active")
        button.setAttribute("aria-pressed", "true")
        tools.appendChild(button)
      }
    }
    this.element.prepend(tools)
  }

  // `.btn small` IS THE EXISTING COMPONENT, not a new one — the same shape the Top/Bottom buttons
  // in the three templates already use (docs/invariants/design-system.md rule 3: a component
  // selector is defined in components.css and nowhere else, and a page sheet only qualifies it).
  // `textContent`, never innerHTML: the label is tracespace's word rather than a filename, but the
  // rule this file follows for the SVG holds for its chrome too.
  toolButton(label, { gerberAction, layerId = null }) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn small"
    button.textContent = label
    button.dataset.action = `gerber#${gerberAction}`
    if (layerId !== null) button.dataset.gerberLayerId = layerId
    return button
  }

  // THE SIDES ARE RENDERED ONCE AND SWAPPED, never re-fetched or re-plotted: a toggle that went
  // back to the network would pay a full parse for a picture already computed, and on a board of a
  // dozen layers that is seconds, not milliseconds.
  //
  // `innerHTML` WITH MARKUP tracespace BUILT, not user input — the strings come from
  // `stringifySvg`, which serialises a hast tree the renderer constructed out of parsed geometry.
  // A Gerber file's own text never reaches the DOM. (The alternative, DOMParser + adoptNode, buys
  // nothing here and loses the `<mask>`/`<clipPath>` id wiring renderBoard depends on unless the
  // whole document is imported intact.)
  show(side) {
    const svg = this.sides && (this.sides[side] || this.sides.top)
    if (!svg) return
    this.side = this.sides[side] ? side : "top"

    // THE VIEW SURVIVES A SIDE SWITCH AND A LAYER TOGGLE, and it has to: both replace the whole
    // <svg>, so a zoomed-in reader who hides the silkscreen would otherwise be thrown back to the
    // fit view and have to find their trace again. Read BEFORE the install, because the install
    // sets `home` and would overwrite the handle's own answer.
    const previous = this.panZoom?.view()
    this.panZoom?.destroy()
    this.panZoom = null

    this.stageTarget.innerHTML = svg
    // THE RENDERED SVG CARRIES `width="10mm" height="10mm"` — its true physical size, which is what
    // makes tracespace's output printable and what makes it 10 pixels wide in a 700px panel. The
    // viewBox is already right, so overriding the two attributes and letting the aspect ratio be
    // preserved scales the board to the stage without touching the geometry. Done HERE rather than
    // in CSS because `width`/`height` ATTRIBUTES beat a stylesheet's `width` for an SVG's intrinsic
    // sizing in exactly the case that matters (a percentage against a flexible container).
    const el = this.stageTarget.querySelector("svg")
    if (el) {
      el.setAttribute("width", "100%")
      el.setAttribute("height", "100%")
      el.setAttribute("preserveAspectRatio", "xMidYMid meet")
      // `home` IS READ OFF THE FIRST RENDER AND KEPT. tracespace composes every side and every
      // layer onto ONE viewBox (renderLayers computes the board shape once and every render is
      // placed in it), so Top, Bottom and any filtered re-compose share it — and reading it again
      // per render would make `Fit` mean "the current picture's box", which for a board with the
      // outline hidden is not the board.
      this.home ||= this.viewBoxOf(el)
      if (this.home) {
        this.panZoom = installPanZoom(el, { home: this.home })
        if (previous) this.panZoom.set(previous)
      }
    }
    if (this.hasSideTarget) {
      this.sideTargets.forEach((b) => b.classList.toggle("active", b.dataset.gerberSide === this.side))
    }
  }

  // `[x, y, w, h]` off the element's own attribute, or null if it has none or it does not parse.
  // A board's box is often negative in y (`viewBox="0 -65 355.05 65"`), so this splits on
  // whitespace AND commas and keeps the signs rather than scanning for numbers.
  viewBoxOf(el) {
    const parts = (el.getAttribute("viewBox") || "").trim().split(/[\s,]+/).map(Number)
    return parts.length === 4 && parts.every(Number.isFinite) ? parts : null
  }
}
