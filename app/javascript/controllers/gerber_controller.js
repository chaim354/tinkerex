import { Controller } from "@hotwired/stimulus"

// ONE GERBER LAYER, OR A WHOLE BOARD, rendered in the browser by tracespace — so this app ships no
// server-side PCB renderer and no sidecar (gerbv is GPL, CLAUDE.md §9).
//
// The module is ONE vendored build (bin/build-tracespace, importmap pin "tracespace") and it is
// imported LAZILY here, on connect, so a page without a Gerber never downloads its 98 KB — the
// KiCanvas rule, and config/importmap.rb pins it `preload: false` so the browser does not fetch it
// anyway (test/integration/web/lazy_bundles_test.rb).
//
// `layersValue` IS A SERVER-BUILT LIST OF {name, url}, AND THE `name` IS LOAD-BEARING. tracespace
// identifies what a layer IS — top copper, solder mask, drill — from the FILENAME, never from the
// bytes, so the name the server put in this list is what decides where the file lands in the
// stackup. That is the same property KiCanvas has (it reads the trailing extension off the URL it
// fetches), which is why both surfaces link the NAMED blob route: the fetch below does not depend
// on it, but nothing is gained by having the two disagree, and a download from the same URL wants
// the real name.
//
// SINGLE vs STACKUP is a SERVER decision, not a count of the layers here. A file page renders the
// one file it is about even when its folder holds a whole board (`singleValue` true → renderLayers,
// one layer, no side toggle); a project panel renders the board (`renderBoard`, top and bottom).
//
// ON S3 THE FETCH BELOW LEAVES THE ORIGIN, as modelviewer_controller.js's and
// kicanvas_controller.js's do: the blob route answers a presigned redirect to the bucket, which
// the browser reads only if the bucket's CORS rule allows this origin (docs/DEPLOY.md), under a
// connect-src the port names for the CSP (FileLayer#presigned_origin). Shared by every
// client-side viewer in this app; the share and chunk_remote deployments stream from Rails and
// never leave the origin.
export default class extends Controller {
  static targets = ["stage", "status", "side"]
  static values = { layers: Array, single: Boolean }

  async connect() {
    try {
      const ts = await import("tracespace")
      // FETCHED IN PARALLEL, but a single failure fails the whole board: a stackup missing its
      // outline layer renders at the wrong size and a stackup missing its drill file renders solid
      // copper over the holes, either of which is a WRONG picture rather than a partial one.
      const files = await Promise.all(
        this.layersValue.map(async ({ name, url }) => {
          const res = await fetch(url)
          if (!res.ok) throw new Error(`${name}: ${res.status}`)
          // `new File([text], name)` rather than the Response's own blob: tracespace's `read()`
          // branches on its argument — a STRING is a filesystem path it would try to open through
          // node:fs — so it has to be a File, and a File carries the name the parser keys on.
          return new File([await res.text()], name)
        })
      )
      // read -> plot -> renderLayers is the whole pipeline; renderBoard composes the two sides out
      // of a renderLayers result, so both branches share everything up to that point.
      const rendered = ts.renderLayers(ts.plot(await ts.read(files)))
      if (this.singleValue) {
        this.sides = { top: ts.stringifySvg(rendered.rendersById[rendered.layers[0].id]) }
      } else {
        const board = ts.renderBoard(rendered)
        this.sides = { top: ts.stringifySvg(board.top), bottom: ts.stringifySvg(board.bottom) }
      }
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

  top() { this.show("top") }
  bottom() { this.show("bottom") }

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
    }
    if (this.hasSideTarget) {
      this.sideTargets.forEach((b) => b.classList.toggle("active", b.dataset.gerberSide === side))
    }
  }
}
