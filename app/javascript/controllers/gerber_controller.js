import { Controller } from "@hotwired/stimulus"
import { installPanZoom } from "lib/svg_pan_zoom"

// ONE GERBER LAYER, OR A WHOLE BOARD, rendered in the browser by tracespace — so this app ships no
// server-side PCB renderer and no sidecar (gerbv is GPL, CLAUDE.md §9). Mounted on the FILE page and
// nowhere else since 2026-09-06, when the project pages' Fabrication panels went: a Gerber is a file
// like any other there (a row, a tile, a link to its page), and the board renders here.
//
// THE CHROME IS THE 3D VIEWER'S (modelviewer_controller.js; the .model-viewer* rules in
// pages/preview.css): a poster with a launch button at rest, then the same stage and bar — Fit,
// Fullscreen, ✕ Image — plus what only a board has, Top/Bottom and one toggle per layer. NOTHING IS
// FETCHED UNTIL THE USER ASKS. `load()` is the launch; it adds `model-viewer--ready` BEFORE the
// fetch for the 3D viewer's reason (the stage must have a size when the SVG lands in it — a
// percentage-height SVG against a display:none box is 0px) and reports loading / ready / failed in
// `data-gerber-state` on this element. `showPoster()` is the way back and KEEPS the parsed render,
// so re-opening is a re-compose and no network (test/system/gerber_test.rb pins that).
//
// The module is ONE vendored build (bin/build-tracespace, importmap pin "tracespace") and it is
// imported LAZILY in `load()`, so a page never downloads its 98 KB until asked — the KiCanvas rule,
// and config/importmap.rb pins it `preload: false` so the browser does not fetch it anyway
// (test/integration/web/lazy_bundles_test.rb).
//
// `layersValue` IS A SERVER-BUILT LIST OF {name, url} — OR ONE ARCHIVE ENTRY — AND THE `name` IS
// LOAD-BEARING. tracespace identifies what a layer IS — top copper, solder mask, drill — from the
// FILENAME, never from the bytes, so the name the server put in this list is what decides where the
// file lands in the stackup. That is the same property KiCanvas has (it reads the trailing
// extension off the URL it fetches), which is why both surfaces link the NAMED blob route: the
// fetch below does not depend on it, but nothing is gained by having the two disagree, and a
// download from the same URL wants the real name. An entry carrying `archive: true` is a zipped
// export and expands to several layers here — `filesFor` below, and FilesHelper#gerber_archive_entry
// is where the server builds that shape.
//
// SINGLE vs STACKUP is a SERVER decision, not a count of the layers here. A layer's page renders
// the one file it is about even when its folder holds a whole board (`singleValue` true →
// renderLayers, one layer, no side buttons, no toggles); a .gbrjob's or a zip's page renders the
// board (`renderBoard`, top and bottom). THE LAYER TOGGLES ARE BUILT HERE, into the template's
// tools span, because their LABELS come from tracespace's own `type`/`side` and cannot exist
// before the parse; Fit, Fullscreen, ✕ Image and the side buttons are in the template precisely
// because they are known without one.
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

// tracespace's LAYER TYPE -> THE WORD THE TOGGLE SHOWS: "top copper", "top silk", "drill" — the
// vocabulary the Fabrication panel's row badges used before the panel went, kept because a maker
// cannot tell top copper from solder mask by looking at three letters of extension.
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
  static targets = ["stage", "status", "side", "dims", "tools"]
  static values = { layers: Array, single: Boolean }

  connect() {
    // HIDDEN LAYERS ARE IDS, NOT INDEXES, and the Set is built before any parse so `compose()` has
    // one shape to read whether or not a toggle has ever been clicked.
    this.hidden = new Set()
    this.side = "top"
    this.generation = 0
    // AT REST, WHATEVER THE MARKUP SAYS. A Turbo Drive back-navigation restores the page from a
    // snapshot taken WITH the stage open — the class, the state attribute, the SVG, the toggles —
    // and then connects this fresh controller, which holds no render for any of it to act on.
    // Resetting to the poster is the honest state; the render is one click away, as it was.
    this.rest()
  }

  disconnect() {
    this.generation++
    this.panZoom?.destroy()
    this.panZoom = null
  }

  // "View board" / "View layer". The first click fetches and parses; a later one — after ✕ Image —
  // reuses the render and only re-composes, which is what keeps that button cheap.
  async load() {
    const gen = ++this.generation
    this.element.classList.add("model-viewer--ready")
    this.state("loading")
    try {
      if (!this.rendered) {
        // ONE IN-FLIGHT RENDER, SHARED — and the assignment BEHIND the generation check. A second
        // launch while the first fetch is still running joins that fetch rather than starting
        // another, so ✕ Image mid-fetch and a relaunch cost one fetch and one parse, not two; and
        // because the render is adopted only by a load that still owns the stage, a superseded one
        // can never swap `this.rendered` out from under what was PAINTED. Both halves are needed:
        // the toggles are keyed on layer ids that are fresh per render, so a stage composed from
        // render A beside a `this.rendered` of B gave a toggle that flipped its own `aria-pressed`
        // while re-composing B unfiltered — the button said hidden over a layer still drawn, with
        // no console error (measured: paths 2 -> 2 where the control gives 2 -> 1).
        //
        // WHAT KEEPS A DISMISSED LOAD'S WORK IS THAT SHARED PROMISE, not the assignment: while the
        // fetch is in flight the next click joins it, and once it has resolved with no viewer left
        // to paint it there is nothing the render belongs to.
        this.pending ||= this.render().finally(() => { this.pending = null })
        const result = await this.pending
        if (gen !== this.generation) return
        this.ts = result.ts
        this.rendered = result.rendered
        // THE BOARD'S SIZE, ONCE PER RENDER, OFF THE RENDER ITSELF — see `sizeFrom`.
        const properties = this.rendered.rendersById[this.rendered.layers[0]?.id]?.properties
        this.size = this.sizeFrom(properties?.width, properties?.height)
      }
      this.compose()
      this.buildTools()
      this.show(this.side)
      this.showDims()
      this.state("ready")
      this.focusViewer()
    } catch (e) {
      this.fail(gen, e)
    }
  }

  // read -> plot -> renderLayers is the whole pipeline; renderBoard composes the two sides out of
  // a renderLayers result, so both branches share everything up to that point.
  //
  // IT ASSIGNS NOTHING AND RETURNS THE PAIR. `load()` owns `this.ts`/`this.rendered` and puts the
  // assignment behind its generation check — see the argument there. The result IS kept, there,
  // which is what makes a layer toggle — and a re-open — free: `compose()` re-composes from that
  // object and never re-fetches, re-reads or re-plots.
  async render() {
    const ts = await import("tracespace")
    // FETCHED IN PARALLEL, but a single failure fails the whole board: a stackup missing its
    // outline layer renders at the wrong size and a stackup missing its drill file renders solid
    // copper over the holes, either of which is a WRONG picture rather than a partial one.
    // `.flat()` because one entry can be a whole archive — see `filesFor`.
    const files = (await Promise.all(this.layersValue.map((layer) => this.filesFor(layer)))).flat()
    return { ts, rendered: ts.renderLayers(ts.plot(await ts.read(files))) }
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

  fullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else {
      this.element.requestFullscreen?.()
    }
  }

  // "✕ Image": back to the poster. The render is KEPT (see load); the stage, the toggles and the
  // dims are cleared because they belong to an open viewer, and the class comes off so the poster
  // returns. `generation++` so a fetch still in flight cannot paint after the dismissal.
  showPoster() {
    this.generation++
    this.rest()
    // The ✕ button that had focus is now hidden; return focus to the launch button.
    this.element.querySelector(".mv-launch button")?.focus()
  }

  rest() {
    this.panZoom?.destroy()
    this.panZoom = null
    this.stageTarget.replaceChildren()
    if (this.hasToolsTarget) this.toolsTarget.replaceChildren()
    if (this.hasDimsTarget) this.dimsTarget.textContent = ""
    this.element.classList.remove("model-viewer--ready")
    this.element.removeAttribute("data-gerber-state")
  }

  fail(gen, error) {
    if (gen !== this.generation) return // superseded — leave newer state alone
    console.warn("[gerber] keeping the poster:", error)
    this.rest()
    this.state("failed")
    if (this.hasStatusTarget) this.statusTarget.textContent = "The viewer could not load."
  }

  state(value) {
    this.element.dataset.gerberState = value
  }

  // After a successful load the launch button that had focus is display:none; move focus to a
  // persistent, now-visible control so keyboard/AT users aren't dropped to <body>.
  focusViewer() {
    this.element.querySelector(".mv-actions button")?.focus()
  }

  // A TOGGLE RE-COMPOSES; IT NEVER RE-FETCHES AND NEVER RE-PLOTS. `renderBoard` takes a
  // renderLayers result and its `layers` list is what it splits by side, so handing it a FILTERED
  // list composes the same board minus those layers — probed against the vendored bundle with a
  // real Fusion export, not assumed. Everything expensive (the fetch, the parse, the plot, the
  // per-layer render) already happened in `render` and is reused.
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

  // THE LAYER TOGGLES, INTO THE TEMPLATE'S TOOLS SPAN. `replaceChildren` makes it idempotent: a
  // re-open after ✕ Image builds them again, and a toggle reads its state off `this.hidden` rather
  // than defaulting to shown, so a layer hidden before the dismissal is still hidden after the
  // re-open — the render it re-composes from is the same one.
  //
  // A SINGLE LAYER HAS NO TOOLS SPAN AT ALL (the template omits it): there is one layer, so a
  // toggle for it is a button whose only effect is to blank the stage, and `renderLayers` has no
  // stackup to re-compose.
  buildTools() {
    if (!this.hasToolsTarget) return
    this.toolsTarget.replaceChildren()
    for (const layer of this.rendered.layers) {
      const shown = !this.hidden.has(layer.id)
      const button = this.toolButton(layerLabel(layer), { gerberAction: "toggleLayer", layerId: layer.id })
      button.classList.toggle("active", shown)
      button.setAttribute("aria-pressed", String(shown))
      this.toolsTarget.appendChild(button)
    }
  }

  // `.btn small` IS THE EXISTING COMPONENT, not a new one — the same shape the Top/Bottom buttons
  // in the template already use (docs/invariants/design-system.md rule 3: a component selector is
  // defined in components.css and nowhere else, and a page sheet only qualifies it).
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
    // A SINGLE LAYER'S SVG CARRIES `width="10.5mm" height="10.5mm"` — its true physical size, which
    // is what makes tracespace's output printable and what makes it 10 pixels wide in a 700px
    // panel; `renderBoard`'s carries NEITHER attribute and would take the stage's size instead. The
    // viewBox is already right in both cases, so setting the two attributes to 100% and preserving
    // the aspect ratio scales the picture to the stage without touching the geometry, and one
    // branch serves both. Done HERE rather than in CSS because `width`/`height` ATTRIBUTES beat a
    // stylesheet's `width` for an SVG's intrinsic sizing in exactly the case that matters (a
    // percentage against a flexible container). THE DIMS THE BAR SHOWS DO NOT COME FROM HERE, for
    // the reason that asymmetry gives — see `sizeFrom`.
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

  // THE BOARD'S PHYSICAL SIZE, IN MILLIMETRES, for the bar's dims — the 3D viewer shows a model's
  // and a board's is the number a maker checks against the fab house's quote. IT IS TAKEN OFF THE
  // RENDER, NEVER OFF THE PAINTED SVG, and that is the whole rule: `renderLayers` writes the size
  // onto the `<svg>` it emits (`width="355.05mm" height="65mm"`, its units the Gerber's), but
  // `renderBoard` — what every "View board" page draws — emits an `<svg>` with NO `width` and NO
  // `height`, so a size read off the element was empty on exactly the pages that say "board". Both
  // branches DO carry it on the per-layer renders: tracespace computes the board shape once and
  // places every layer in it, so the FIRST layer's `properties.width`/`.height` are the board's own
  // extent whichever branch composes them. `load()` reads it once, from the render every side and
  // every re-compose share. Inches are converted so the bar never shows two units, and anything
  // unparseable — a missing attribute included — shows nothing rather than a wrong number.
  sizeFrom(width, height) {
    const dim = (value) => {
      const m = /^(-?\d*\.?\d+)(mm|in)$/.exec(value || "")
      return m ? Number(m[1]) * (m[2] === "in" ? 25.4 : 1) : null
    }
    const w = dim(width)
    const h = dim(height)
    return w !== null && h !== null ? [w, h] : null
  }

  showDims() {
    if (!this.hasDimsTarget || !this.size) return
    const [w, h] = this.size
    this.dimsTarget.textContent = `${w.toFixed(1)} × ${h.toFixed(1)} mm`
  }

  // `[x, y, w, h]` off the element's own attribute, or null if it has none or it does not parse.
  // A board's box is often negative in y (`viewBox="0 -65 355.05 65"`), so this splits on
  // whitespace AND commas and keeps the signs rather than scanning for numbers.
  viewBoxOf(el) {
    const parts = (el.getAttribute("viewBox") || "").trim().split(/[\s,]+/).map(Number)
    return parts.length === 4 && parts.every(Number.isFinite) ? parts : null
  }
}
