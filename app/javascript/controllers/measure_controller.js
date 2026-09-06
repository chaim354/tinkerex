import { Controller } from "@hotwired/stimulus"
import { PAPERS, printSheets } from "lib/print_sheet"
import { exportSvg } from "lib/export_svg"
import { SVG_NS, shapeElement, unionBox } from "lib/shape_svg"
import { installPanZoom } from "lib/svg_pan_zoom"

// Measure view: click a contour, read its size in mm.
//
// Serves .lbrn/.lbrn2, .mage, .dxf and .svg — every format Maker::Previews::Geometry can build a
// payload for. The page shows a picture at rest (the app's own embedded render for LightBurn and
// MillMage, a server thumbnail for DXF, the file itself for SVG); each of those is a raster or an
// opaque document with no mapping back to millimetres, so measuring needs a vector surface. This
// controller fetches the server's geometry payload (GET /files/:id/geometry -> a blob URL) and
// builds an SVG from the coordinates.
//
// FORMAT-AGNOSTIC BY CONSTRUCTION, and worth keeping that way: nothing below branches on file
// type. It reads only the wire contract — job box, shapes, colours — so a fifth format needs a
// server-side traversal and NOT a line of JavaScript. That is why the shared payload builder
// exists; see the Geometry module.
//
// BUILT WITH createElementNS FROM NUMBERS, NEVER innerHTML. Maker::Previews::Svg rasterizes user
// SVG precisely because the web layer refuses to inline it; constructing elements from parsed
// coordinates sidesteps that rule instead of carving an exception into it. That reasoning binds
// hardest on the .svg leg, where the bytes we are measuring ARE an SVG the layer refuses to
// inline — the payload is parsed coordinates, so nothing of the user's markup reaches the DOM.
// The contour elements themselves come from lib/shape_svg, which builds them the same way and is
// the ONE definition shared with the print sheet and the exporter; SVG_NS is imported from there
// too, so the namespace string is not spelled twice.
//
// Lazy by design: nothing is fetched until Measure is clicked. The payload reaches 281 KB gzipped
// on the densest real files, and most pages are never measured.

// Must match Maker::Previews::Geometry::SCHEMA_VERSION — ONE number for all four formats, since
// this parser is one parser.
const SCHEMA_VERSION = 1

// The job's retry_on uses polynomial backoff over 5 attempts, which can run for minutes — far
// longer than anyone watches a spinner. Poll a bounded number of times, then say so honestly.
//
// WHAT THE USER WAITS IS THE CUMULATIVE DELAY, NOT ANY SINGLE STEP — and reading this list as
// individual pauses is exactly how the previous schedule [400, 800, 1500, 2500, 4000, 6000]
// looked unremarkable while being anything but. It checked at 400, 1200, 2700 and 5200 ms, so a
// render finishing at 3.5 s went unnoticed until 5.2 s. Nearly two seconds of the observed wait
// was this array rather than the server.
//
// These check at 250, 650, 1250, 2150, 3450, 5250, 7750, 11250, 16250 ms — five looks inside the
// first 3.5 s, where real renders land, and still bounded so a wedged job stops being polled.
const POLL_DELAYS_MS = [250, 400, 600, 900, 1300, 1800, 2500, 3500, 5000]

// Remembered across visits: the paper in your printer does not change between files.
const PAPER_KEY = "measure.paper"
// A guess about the operator rather than a measurement — one constant to change.
const DEFAULT_PAPER = "Letter"

export default class extends Controller {
  // `name` IS REQUIRED, NOT COSMETIC. Stimulus silently ignores a data-*-value attribute the
  // controller does not declare, so `this.nameValue` is `undefined` until it appears here — no
  // error, no warning, just an empty filename on every printed sheet.
  static values = { url: String, name: String }
  static targets = ["stage", "dims", "fallback", "paper", "printButton", "svgButton"]

  connect() {
    this.aborted = false
    this.hovered = null
    // THE SELECTION, AND SINCE 2026-09-03 THE ONLY SELECTION STATE THERE IS. Membership is by
    // IDENTITY on the payload's own shape objects, reached through node.__shape — so nothing about
    // the wire format has to change to give a contour an id.
    //
    // IT WAS TWO STATES UNTIL THEN, AND THAT IS WHAT THE USER ASKED TO COLLAPSE: a transient
    // `selected` contour (the measurement highlight, red) beside this print set (blue), which
    // could only be added to while a "Select parts" MODE was on. There is no mode now — every
    // click marks — and one colour answers the one question, which is why `selecting`, `selected`
    // and the toggle target are absent rather than merely unused. See §14h.
    this.marked = new Set()
    this.nodeByShape = new Map()
  }

  disconnect() {
    this.aborted = true
    clearTimeout(this.pollTimer)
  }

  async load() {
    this.setStatus("Loading geometry…")
    try {
      const payload = await this.fetchPayload()
      if (this.aborted || !payload) return
      this.draw(payload)
    } catch (e) {
      console.warn("[measure] keeping the thumbnail:", e)
      this.setStatus(e.message || "Could not load geometry.")
    }
  }

  showPoster() {
    this.element.classList.remove("measure-view--ready")
    this.stageTarget.replaceChildren()
    this.setStatus("")
    this.hovered = this.svg = null
    // AND THE SELECTION WITH IT. Every leak here is silent, because the poster hides the whole
    // actions bar: a set left populated goes on being promised by the print button — and printed
    // — over shapes that are no longer marked, no longer drawn, and no longer even the objects
    // the next payload will hand out.
    this.marked.clear()
    this.nodeByShape.clear()
    this.refreshPrintBar()
  }

  // Poll the endpoint until it reports ready, then fetch the payload from the blob URL it names.
  async fetchPayload() {
    for (let attempt = 0; attempt <= POLL_DELAYS_MS.length; attempt++) {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error(`Geometry request failed (${res.status}).`)
      const body = await res.json()

      if (body.status === "ready" && body.url) {
        const blob = await fetch(body.url)
        if (!blob.ok) throw new Error("Could not read the geometry payload.")
        const payload = await blob.json()
        if (payload.v !== SCHEMA_VERSION) {
          throw new Error("This preview needs a newer version of the page — reload.")
        }
        return payload
      }
      if (body.status === "failed" || body.status === "unsupported") {
        throw new Error(body.error || "No geometry available for this file.")
      }
      if (attempt === POLL_DELAYS_MS.length) break
      this.setStatus("Generating geometry…")
      await this.sleep(POLL_DELAYS_MS[attempt])
      if (this.aborted) return null
    }
    throw new Error("Still generating — reload to check.")
  }

  sleep(ms) {
    return new Promise((resolve) => { this.pollTimer = setTimeout(resolve, ms) })
  }

  draw(payload) {
    this.colors = payload.colors || {}
    // WHAT THE SERVER'S TRAVERSAL COULD NOT READ, `{ type: count }` or absent. Set BEFORE the
    // empty-shapes return below, because that branch is exactly the case it exists for.
    this.unreadable = payload.u || null
    this.byObject = new Map()
    for (const s of payload.shapes) {
      if (!this.byObject.has(s.o)) this.byObject.set(s.o, [])
      this.byObject.get(s.o).push(s)
    }

    if (!payload.shapes.length) {
      // "No measurable geometry in this file" IS A LIE ABOUT A FILE THAT IS ENTIRELY GEOMETRY,
      // and it was the observed harm rather than a hypothetical one: a real .dxf of four SPLINEs
      // read exactly this, having measured none of itself. The clause is what makes the empty
      // stage legible instead of accusing the file.
      const missing = this.unreadableLabel()
      this.setStatus(missing ? `No measurable geometry in this file · ${missing}` :
                               "No measurable geometry in this file.")
      return
    }

    const svg = document.createElementNS(SVG_NS, "svg")
    const pad = Math.max(payload.job.w, payload.job.h) * 0.02
    this.home = [payload.job.x - pad, payload.job.y - pad,
                 payload.job.w + pad * 2, payload.job.h + pad * 2]
    // THE viewBox ITSELF IS WRITTEN BY installPanZoom, through the `bindInteractions` call at the
    // bottom of this method — it sets `home` as it installs, so this element gets its viewBox
    // before the browser paints (nothing between here and there yields to the event loop, and the
    // element is not in the document until `replaceChildren` a few lines below either).
    // `preserveAspectRatio` stays HERE because the lib's screen ->
    // user-space maths assumes it and cannot set it: the element is the caller's, and a caller that
    // wanted `none` would need different maths, not a silently overridden attribute.
    svg.setAttribute("preserveAspectRatio", "xMidYMid meet")

    // SMALLEST CONTOUR WINS, VIA PAINT ORDER. Appending in DESCENDING bbox-area order puts small
    // shapes on top, so the browser's own topmost-wins hit dispatch selects the hole rather than
    // the plate it sits in. That is the entire selection algorithm — no point-in-polygon code.
    const ordered = [...payload.shapes].sort((a, b) => this.area(b) - this.area(a))
    for (const s of ordered) {
      const top = this.contourNode(s)
      svg.appendChild(top)
      // The DRAWN line, not the group and not the transparent hit twin — recorded so marking can
      // reach a contour it was not handed by an event. Mark the GROUP instead and nothing visibly
      // changes: `stroke` is inherited, and the line's own presentation attribute outranks what it
      // would inherit, so the contour keeps its layer colour while the class sits one level up.
      this.nodeByShape.set(s, top.__visible || top)
    }
    this.allShapes = payload.shapes

    this.stageTarget.replaceChildren(svg)
    this.svg = svg
    this.element.classList.add("measure-view--ready")
    this.setStatus(this.restingStatus())
    this.bindInteractions(svg)
    // AFTER bindInteractions, DELIBERATELY. populatePaper reads localStorage, which throws in a
    // blocked or partitioned storage context — and draw() has already inserted the SVG and applied
    // --ready by this point, so a throw here USED to leave a drawn, ready-looking Measure view with
    // no hover, click, pan or zoom, from a preference-remembering nicety. Binding first means the
    // worst case costs the paper picker, not measuring. Neither call needs the listeners.
    this.populatePaper()
    // AND THE PRINT BAR, WHICH IS WHY THE ERB'S LITERALS CANNOT DRIFT. Dropping this line alone is
    // GREEN — probed, not assumed — because the partial happens to render exactly what
    // refreshPrintBar() would write ("Print all", Clear `hidden`), and the launch button is
    // display:none once --ready, so draw() cannot run twice without showPoster() (which refreshes
    // the bar itself). That agreement is not a coincidence to rely on, it is what this call
    // GUARANTEES: with the partial's label changed to "Print" the whole file stays green with this
    // line and goes red in five places without it. It is what makes the controller, not the
    // template, the one definition of the bar at rest.
    this.refreshPrintBar()
  }

  // POPULATED FROM print_sheet.js's PAPERS TABLE, not listed in the ERB: a second copy of the
  // paper list is a second definition that drifts, and this select is hidden until the controller
  // runs anyway.
  //
  // THE `options.length` EARLY RETURN IS NOT TIDINESS. draw() runs again on every ✕ Image ->
  // Measure round trip and on every re-load of the payload, so without it the select grows four
  // more entries each time.
  //
  // AND `PAPERS[saved] ?` IS NOT A NIL GUARD DRESSED UP. A key this build no longer offers — a
  // stale one, or a hand-edited one — leaves NO option marked selected, and a <select> with
  // nothing selected answers its FIRST option. That is A4, because that is where PAPERS starts,
  // so an unrecognised value would silently change the paper rather than being ignored.
  //
  // NO `hasPaperTarget` GUARD, for refreshPrintBar's reason one method down: the select sits in
  // the same always-rendered span as the buttons, so the target exists whenever this controller
  // does. It was here and was removed — it could not fail (dropping it left all 73 tests green),
  // and it did not protect what it named, since `print()` reads `this.paperTarget` unguarded
  // regardless. A guard on one of two readers is worse than none: it hides the shape of the
  // problem without preventing it.
  //
  // The `options.length` return is a different claim and does carry weight — it makes a second
  // draw() idempotent rather than appending a duplicate set of four options.
  populatePaper() {
    if (this.paperTarget.options.length) return
    const saved = localStorage.getItem(PAPER_KEY)
    const chosen = PAPERS[saved] ? saved : DEFAULT_PAPER
    // THE LABEL COMES FROM THE TABLE'S OWN `name`, THE VALUE FROM THE KEY, AND NOTHING TODAY CAN
    // TELL THEM APART — every PAPERS key is spelled exactly like its `name`, so `option.textContent
    // = key` is a GREEN mutation, measured. The `name` field exists precisely so a key like `Legal`
    // could one day read "US Legal"; keeping the two sources distinct is what makes that a data
    // change rather than a code change. Nothing here is broken — this is a limit of the data,
    // recorded rather than argued away.
    for (const key of Object.keys(PAPERS)) {
      const option = document.createElement("option")
      option.value = key
      option.textContent = PAPERS[key].name
      option.selected = key === chosen
      this.paperTarget.appendChild(option)
    }
  }

  paperChanged() {
    localStorage.setItem(PAPER_KEY, this.paperTarget.value)
  }

  print() {
    const shapes = this.targetShapes()
    // NOT DEAD, BUT ONLY REACHABLE BY DRIVING THIS METHOD DIRECTLY. `allShapes` is undefined
    // between connect() and the first successful draw(), and in that window the button is
    // display:none (`.measure-actions` without --ready), so no click can get here. What the guard
    // buys is the difference between doing nothing and putting a raw TypeError from buildSheets
    // into the readout as the answer to a button press. Pinned by a test that calls print()
    // directly, because nothing else can.
    if (!shapes || !shapes.length) return
    try {
      // THE `||` IS THE SAME KIND OF BELT, and reachable in the same one state: an unpopulated
      // select answers `value === ""`, which is no key here. Without it buildSheets gets
      // `undefined` for its paper and dies in contentBox, so a deployment that ever lost
      // populatePaper would lose Print with it rather than degrading to the default.
      printSheets(shapes, PAPERS[this.paperTarget.value] || PAPERS[DEFAULT_PAPER], {
        name: this.nameValue,
        // LOCAL, NOT UTC. `toISOString()` gives the same ISO shape and stamps an evening print in
        // the Americas with TOMORROW's date — on a sheet whose header exists so a page found on a
        // bench next week can be trusted. "en-CA" is the ISO-shaped locale.
        date: new Date().toLocaleDateString("en-CA"),
        // THE CONTROLLER'S OWN sizeLabel, so the paper and the readout have one definition between
        // them. It reads `d` and `b` — the server's full-resolution numbers — never `p`, the
        // THINNED drawing points: re-deriving a size from those under-reports every curve, and
        // a re-derivation loses the ⌀ outright, because THIS SIDE HAS NO CIRCULARITY TEST — `d`
        // is decided server-side from full-resolution points (CLAUDE.md §14h). Measured: the
        // mutation prints "10 × 10 mm" where "⌀10 mm" belongs.
        sizeLabel: (shape) => this.sizeLabel(shape),
      })
    } catch (e) {
      // THE SHEET-COUNT REFUSAL LANDS HERE, AND IT HAS TO REACH THE READOUT rather than the
      // console: buildSheets throws before any frame exists, so a swallowed message is a Print
      // button that does nothing whatsoever. The message names the size that caused it, which is
      // the only part of it that tells the user what to do differently.
      //
      // AND IT LOGS, because the catch is unconditional and cannot tell a refusal from a bug. Probed:
      // make `furniture()` throw a TypeError and "prints without logging a console error" stays
      // GREEN while the user reads a developer string as the reason their print refused. `load()`
      // twenty lines up warns for exactly this reason before setting its own status.
      console.warn("[measure] print refused:", e)
      this.setStatus(e.message)
    }
  }

  // THE SAME TARGET SET print() USES, resolved by the same method — so the two buttons beside each
  // other can never act on different shapes.
  //
  // THE BLOB IS BUILT AND RELEASED HERE; lib/export_svg builds the DOCUMENT and knows nothing about
  // downloads. That is the split print_sheet.js draws between renderSheet and buildPrintFrame, and
  // it is what lets the export be asserted as a string in a test rather than as a file on disk.
  downloadSvg() {
    const shapes = this.targetShapes()
    // The same guard, and the same window, as print()'s: `allShapes` is undefined between
    // connect() and the first successful draw(), and the button is display:none throughout it.
    if (!shapes || !shapes.length) return

    let url
    try {
      const blob = new Blob([ exportSvg(shapes, { colors: this.colors }) ], { type: "image/svg+xml" })
      url = URL.createObjectURL(blob)
      const a = document.createElement("a")
      a.href = url
      // The SOURCE file's base name plus a suffix, never the source name itself: exporting a
      // subset of `plate.svg` to a file also called `plate.svg` is a download that silently
      // shadows the original in the browser's download folder.
      a.download = `${this.nameValue.replace(/\.[^.]+$/, "")}-parts.svg`
      a.click()
    } catch (e) {
      // REACHES THE READOUT, not just the console — exportSvg throws before any file exists, so a
      // swallowed message is a button that does nothing whatsoever. AND IT LOGS, because this
      // catch cannot tell a refusal from a bug: print()'s own catch carries the same pair for the
      // same reason.
      console.warn("[measure] export refused:", e)
      this.setStatus(e.message)
    } finally {
      // RELEASED EVEN WHEN THE CLICK THREW. An object URL pins its Blob for the lifetime of the
      // document, and this view is reachable repeatedly through the ✕ Image -> Measure round trip.
      if (url) URL.revokeObjectURL(url)
    }
  }

  area(s) {
    return Math.max(s.b[2] - s.b[0], 0.01) * Math.max(s.b[3] - s.b[1], 0.01)
  }

  // A bitmap draws as a dashed placeholder: its base64 is excluded from the payload on purpose
  // (one real file is 1.45 MB as SVG and 0.1 KB as geometry), and a measuring view has no use
  // for the photo — only for the rectangle it occupies.
  //
  // THE ELEMENT COMES FROM lib/shape_svg, shared with the print sheet and the exporter — so a
  // LightBurn <Ellipse>, a DXF CIRCLE/ARC and an SVG <circle> draw as the primitive the FILE
  // described, the same one the thumbnail beside this view has always drawn.
  contourNode(shape) {
    const node = shapeElement(document, shape)
    node.setAttribute("class", shape.i ? "measure-bitmap" : (shape.k ? "measure-contour" : "measure-contour measure-contour--open"))
    // LightBurn's own layer colour, sent by the server so the palette has ONE definition (see
    // LbrnGeometry#layer_colors).
    //
    // A PRESENTATION ATTRIBUTE, NOT node.style — and the difference is the whole highlight
    // mechanism. An inline style beats a stylesheet, so setting style.stroke here would make
    // .measure-contour--hover and --marked unable to recolour anything: clicking a contour would
    // change its width and nothing else. A presentation attribute sits BELOW every CSS rule in
    // the cascade, so the layer colour shows at rest and the highlight classes still win. For the
    // same reason .measure-contour must not declare a stroke of its own — a class rule would beat
    // this attribute and every layer would draw identically.
    if (!shape.i) node.setAttribute("stroke", this.colors[shape.c] || "#000000")
    node.__shape = shape
    if (shape.k || shape.i) return node

    // An open contour has no interior to click and a hairline stroke to aim at. Group it with a
    // transparent fat twin so the hit area is finger-sized while the drawn line stays 1px.
    //
    // THE TWIN IS ALWAYS A POLYLINE FROM shape.p, EVEN WHEN THE DRAWN NODE IS AN ARC. It is an
    // invisible 8px target, so approximating the arc costs nothing visible and keeps the twin one
    // element — and it must be built from the points here rather than reusing a `points` string,
    // because the visible node no longer necessarily has one.
    const group = document.createElementNS(SVG_NS, "g")
    const hit = document.createElementNS(SVG_NS, "polyline")
    hit.setAttribute("points", shape.p.map(([ x, y ]) => `${x},${y}`).join(" "))
    hit.setAttribute("class", "measure-contour--hit")
    hit.__shape = shape
    hit.__visible = node // so hover/selection colours the drawn line, not the invisible twin
    group.appendChild(hit)
    group.appendChild(node)
    // So draw() can resolve a group to the line it should style, the same way styleNode() does.
    group.__visible = node
    return group
  }

  // HOVER, CLICK AND HIT-TESTING ARE THIS FILE'S; THE viewBox IS lib/svg_pan_zoom's. The wheel,
  // drag-pan and pinch handlers the four lines below used to add live there now, so the Gerber
  // stage can have the same hands without a second copy of the letterbox maths (§14d). What stays
  // here is everything that knows what a CONTOUR is — which the lib deliberately does not.
  //
  // ORDER STILL MATTERS AND IS UNCHANGED: hover binds before the lib's own `pointermove`, and the
  // click handler below reads `panZoom.didPan()` rather than a flag of its own.
  bindInteractions(svg) {
    svg.addEventListener("pointermove", (e) => this.hover(e))
    svg.addEventListener("pointerleave", () => this.clearHover())
    svg.addEventListener("click", (e) => this.pick(e))
    // draw() runs again on every ✕ Image -> Measure round trip, each time on a NEW <svg>; the old
    // handle's listeners die with the element it held, but dropping it explicitly keeps that a
    // statement rather than a thing to work out.
    this.panZoom?.destroy()
    // NO `onChange` HERE, DELIBERATELY. The lib offers one and gerber_controller.js needs it (it
    // has to carry a view across a re-render); nothing in this file reads the current viewBox back,
    // so a `this.view` mirror would be state written and never read. The handle's `view()` is the
    // door if a reader ever appears.
    this.panZoom = installPanZoom(svg, { home: this.home })
  }

  // `event.target` IS NOT TRUSTWORTHY ON A CLICK HERE, AND THE PAN'S POINTER CAPTURE IS WHY.
  // lib/svg_pan_zoom captures the pointer on the <svg> so a drag that wanders off the element keeps
  // panning — and a captured pointer retargets its own compatibility mouse events too, so
  // `mouseup` is delivered to the <svg> rather than the contour. `click` is then dispatched at the
  // nearest common ancestor of the mousedown and mouseup targets, which is that same <svg>.
  //
  // Measured, not reasoned: instrumenting one ordinary click on a contour logged
  //   pointerdown -> polygon, mousedown -> polygon, pointerup -> svg, mouseup -> svg, click -> svg
  // while `document.elementFromPoint` at those exact coordinates answered `polygon` every time.
  // So reading `event.target` selects NOTHING on the one gesture the whole view exists for —
  // silently, with no error, looking exactly like a shape that simply isn't clickable.
  //
  // Falling back to the pointer position asks the browser's own hit test the question we actually
  // have ("what is under the cursor"), independently of capture, and still honours the paint order
  // `draw` sorted for — elementFromPoint returns the TOPMOST element, which is the smallest
  // contour. `event.target` is kept as the fast path so hover, which fires on every pointermove
  // and is never captured, does not force a hit test per move.
  shapeAt(event) {
    const node = event.target && event.target.__shape
      ? event.target
      : document.elementFromPoint(event.clientX, event.clientY)
    return node && node.__shape ? node : null
  }

  // WHAT WAS HIT IS NOT ALWAYS WHAT TO STYLE. An open contour is hit through a transparent fat
  // twin (see contourNode), so highlighting the node the event landed on would change the colour
  // of something invisible and nothing would appear to happen. `__visible` points at the drawn
  // line; closed contours are their own hit target and have none. Only `hover` calls this now —
  // the selection reaches its node through `nodeByShape`, which `draw` populates with the very
  // same `top.__visible || top` resolution.
  styleNode(node) {
    return node.__visible || node
  }

  hover(event) {
    // `panning()` IS LIVE STATE, NOT `didPan()`. It is true from the first pointerdown of a drag,
    // before the slop is crossed — which is what this needs: repainting a hover highlight on every
    // move of a pan is the work being skipped, and a slop-gated answer would still do it for the
    // first few pixels of every drag.
    if (this.panZoom?.panning()) return
    const node = this.shapeAt(event)
    if (node === this.hovered) return
    if (this.hovered) this.styleNode(this.hovered).classList.remove("measure-contour--hover")
    this.hovered = node
    if (this.hovered) this.styleNode(this.hovered).classList.add("measure-contour--hover")
  }

  clearHover() {
    if (this.hovered) this.styleNode(this.hovered).classList.remove("measure-contour--hover")
    this.hovered = null
  }

  // EVERY CLICK SELECTS, AND CLICKING A SELECTED CONTOUR AGAIN DROPS IT. There is no mode to
  // enter first — that was the user's request on 2026-09-03, and the deselect half of it is
  // deliberate rather than incidental: without it there is no way to drop ONE part from a
  // gathered set short of clearing the lot and rebuilding it.
  pick(event) {
    // A DRAG THAT ENDED ON A CONTOUR IS NOT A SELECTION. The flag is the lib's and is cleared by
    // the next pointerdown, so this reads it and does not have to reset it.
    if (this.panZoom?.didPan()) return
    const node = this.shapeAt(event)
    // EMPTY SPACE CLEARS THE WHOLE SELECTION — AND THIS REVERSED AN EARLIER RULE ON 2026-09-03, AT
    // THE USER'S REQUEST. It used to drop the measurement highlight ALONE and to leave the print
    // set deliberately untouched, on the grounds that a stray background click in select mode must
    // not throw away the parts you had gathered. With one state there is nothing else for a
    // background click to mean, and it is still the cheap way back to "Print all" that made the
    // background clickable in the first place. The cost is real and was accepted: a stray click
    // now empties the set, recoverable only by picking the parts again.
    if (!node) { this.clearMarks(); return }

    const shape = node.__shape
    const siblings = this.byObject.get(shape.o) || [shape]
    // Alt-click widens to the whole <Shape> object — every contour the parser gave the same
    // object id, which for a Text is its entire rendered outline rather than one letter.
    const useObject = event.altKey && siblings.length > 1

    this.toggleMarks(useObject ? siblings : [shape])
    // BOTH HALVES, because picking parts and learning their sizes are one gesture: a click that
    // silenced the measurement would make you unpick a part to read its size.
    //
    // AND `contourLabel` RATHER THAN THE BARE `sizeLabel` THE SELECTING ARM USED TO PASS, so the
    // "⌥ for the whole object" hint survives the merge. It is the ONLY place the app says that
    // gesture exists, and it used to appear only OUTSIDE select mode — which is now nowhere.
    const size = useObject ? this.dims(unionBox(siblings)) : this.contourLabel(shape, siblings)
    this.setStatus(`${size} · ${this.selectionStatus()}`)
  }

  // The message the view rests at, and the one definition of it: `draw` opens with it and
  // `clearSelection` returns to it, so a deselect cannot leave a size on screen with nothing
  // highlighted to own it.
  restingStatus() {
    const missing = this.unreadableLabel()
    return `${this.allShapes.length} shapes${missing ? ` · ${missing}` : ""} · click one to measure`
  }

  // "2 SPLINE not readable", or "" when the whole file was read. THE ONE PLACE THIS SENTENCE IS
  // WRITTEN, because two surfaces need it: the resting line, and `draw`'s empty-file branch —
  // which never reaches restingStatus() and is the case the mechanism was built for.
  //
  // EVERY TYPE, UNCAPPED. A cap belongs nowhere in an honesty backstop: hiding the tail of a
  // report about hidden geometry is the same defect one layer out. The real corpus carries one or
  // two types per file.
  unreadableLabel() {
    if (!this.unreadable) return ""
    const parts = Object.entries(this.unreadable).map(([type, n]) => `${n} ${type}`)
    return `${parts.join(", ")} not readable`
  }

  // `clearSelection`, `toggleSelect` AND `applySelecting` LIVED HERE AND WENT WITH THE MODE on
  // 2026-09-03. The first cleared the measurement highlight alone; the other two owned the "Select
  // parts" / "Done selecting" toggle and its `aria-pressed`, and `applySelecting` existed to be
  // the ONE definition of what that button looked like in a given state, because showPoster() had
  // to leave the mode too. There is no mode and no toggle, so there is nothing for them to say.

  // AN ALT-CLICK ON A PARTLY-MARKED OBJECT COMPLETES IT rather than inverting it: flipping each
  // contour individually would leave the object half in the print set, which is never what was
  // meant by clicking the object.
  toggleMarks(shapes) {
    const adding = shapes.some((s) => !this.marked.has(s))
    for (const shape of shapes) {
      const node = this.nodeByShape.get(shape)
      if (adding) {
        this.marked.add(shape)
        node?.classList.add("measure-contour--marked")
      } else {
        this.marked.delete(shape)
        node?.classList.remove("measure-contour--marked")
      }
    }
    this.refreshPrintBar()
  }

  // THE ONE WAY BACK TO AN EMPTY SELECTION, and it writes the RESTING line rather than
  // `selectionStatus()`'s "nothing selected" arm. Both doors into it — a click on empty space and
  // the Reset button — mean "start again", and the resting line is what the view says when it has
  // never been touched, so saying anything else here would give one state two sentences depending
  // on how you reached it. The empty arm is still reachable, and only where it is the honest
  // answer: unpicking the LAST part leaves its size on screen beside "nothing selected".
  //
  // NO `allShapes` GUARD AROUND `restingStatus()`, DELIBERATELY. Both callers exist only after a
  // successful draw() — `pick` needs a drawn SVG to have been clicked, and Reset lives in
  // `.measure-actions`, which is `display: none` without --ready — so the same argument
  // refreshPrintBar() makes about its targets applies: a guard that cannot fail asserts a
  // condition that does not exist.
  clearMarks() {
    for (const shape of this.marked) {
      this.nodeByShape.get(shape)?.classList.remove("measure-contour--marked")
    }
    this.marked.clear()
    this.refreshPrintBar()
    this.setStatus(this.restingStatus())
  }

  selectionStatus() {
    const n = this.marked.size
    if (!n) return "nothing selected · Print all prints the whole file"
    return `${n} part${n === 1 ? "" : "s"} · ${this.dims(unionBox([...this.marked]))}`
  }

  // TWO ARMS, IN PRECEDENCE ORDER, WITH ONE DEFINITION — and there were THREE until 2026-09-03.
  // They were written out twice — once in print() and once in refreshPrintBar() — under a comment
  // saying the two "must not drift", which is prose where a mechanism belongs. The exporter would
  // have been a third copy, and three copies of a precedence rule is §14d's five port_writable?
  // branches in miniature.
  //
  //   marked set -> the set        "Print 3 parts"
  //   else       -> the whole file "Print all"
  //
  // THE MIDDLE ARM WAS "else the contour under the measurement", and it existed so that measuring
  // a part was enough to aim the buttons at it — "Select parts is not a toll gate on printing one
  // part". Selecting IS the measuring click now, so the first arm does that job; keeping a second
  // state for it would be two answers to one question, which is the shape §14a spends its length
  // refusing.
  targetShapes() {
    return this.marked.size ? [ ...this.marked ] : this.allShapes
  }

  // WHAT THE BUTTONS CALL THAT SET. Same two arms, same order, derived from the same state, so a
  // label can no longer describe one target while an action performs another.
  targetNoun() {
    const n = this.marked.size
    return n ? `${n} part${n === 1 ? "" : "s"}` : "all"
  }

  // NO `hasPrintButtonTarget` GUARD, DELIBERATELY, and the plan's draft had one. All six controls
  // live in ONE always-rendered <span class="measure-actions">, so the target exists whenever this
  // controller is connected. A guard that cannot fail asserts a condition that does not exist.
  //
  // THERE ARE FOUR CALLERS NOW, NOT THREE, AND THE FOURTH RETIRED HALF OF THIS ARGUMENT. The
  // original three — toggleMarks, clearMarks, showPoster — are each reachable only once the view
  // is drawn (toggleMarks and clearMarks through a click on the SVG, showPoster off a button in
  // that same span). `draw()` is not: it runs off the LAUNCH button, which lives in a different
  // span, so
  // the clause this comment used to end on — "in the one future it was written for, a partial that
  // omits the bar, nothing reaches this method at all" — is now FALSE and is deleted rather than
  // left to be relied on. Such a partial would break draw() itself, and `populatePaper` and
  // `print()` with it; the answer then is that the partial declares the controls, not that four
  // methods each grow a guard.
  // THE LABEL ALWAYS NAMES THE TARGET IN FORCE, and it can no longer do otherwise: the noun comes
  // from `targetNoun()` and the shapes `print()` acts on from `targetShapes()`, so the two halves
  // of the claim are one definition rather than two spellings kept in step by a comment. Two
  // wordings survive the merge — "Print all" and "Print 3 parts"; "Print selected" went with the
  // middle arm on 2026-09-03, since a selected contour IS a one-part set now.
  refreshPrintBar() {
    const noun = this.targetNoun()
    this.printButtonTarget.textContent = `Print ${noun}`
    // THE SVG BUTTON'S TEXT DOES NOT MOVE, SO ITS ACCESSIBLE NAME MUST. Both are written here,
    // from one targetNoun(), so the two buttons cannot come to describe different sets. Its
    // visible text reads "Download SVG" as of 2026-09-03 (it was "SVG"), which is still CONSTANT:
    // a second count-bearing label beside "Print 3 parts" is noise, and the count is what the
    // accessible name carries. NO `hasSvgButtonTarget` GUARD, for the reason the comment above
    // gives about the Print button: it is a control in the same always-rendered span, so it exists
    // whenever this controller is connected, and a guard that cannot fail asserts a condition that
    // does not exist. The at-rest literals in _measure.html.erb are this same string with
    // `noun` = "all".
    const label = `Download ${noun} as SVG`
    this.svgButtonTarget.setAttribute("aria-label", label)
    this.svgButtonTarget.setAttribute("title", label)
  }

  // THE SIZE, PLUS THE ONE PLACE THE APP SAYS ⌥-CLICK EXISTS. `pick` composes this with
  // `selectionStatus()`, so a contour that stands alone reads exactly as it always did and only a
  // multi-contour object costs the extra clause.
  //
  // ITS SIBLING `objectLabel` IS GONE (2026-09-03). It read "30 × 10 mm · whole object, 2
  // contours" for the ⌥ case, and beside `selectionStatus()`'s own "2 parts" that is the same
  // count twice in one line — so the widened arm passes the union dims and lets the selection
  // summary do the counting.
  contourLabel(shape, siblings) {
    let label = this.sizeLabel(shape)
    if (siblings.length > 1) {
      label += ` · part of a ${siblings.length}-contour object (⌥ for ${this.dims(unionBox(siblings))})`
    }
    return label
  }

  // ⌀ only when the server said so. Circularity is decided server-side, from full-resolution
  // points, so the client never re-derives a measurement from the thinned drawing points.
  sizeLabel(shape) {
    return shape.d != null ? `⌀${this.mm(shape.d)} mm` : this.dims(shape.b)
  }

  dims(box) {
    return `${this.mm(box[2] - box[0])} × ${this.mm(box[3] - box[1])} mm`
  }

  // `unionOf` LIVED HERE AND WAS BYTE-IDENTICAL TO print_sheet's `unionBox`. The exporter would
  // have been a third copy, so the one definition moved to lib/shape_svg and both import it.

  mm(n) {
    return (Math.round(n * 10) / 10).toLocaleString()
  }

  // RESET IS BOTH HALVES OF "START AGAIN": the view goes home AND the selection empties. There is
  // no separate Clear button — one button, one meaning, and the set is not a thing you can leave
  // behind by resetting the view and assuming you had.
  //
  // IT CLEARS UNCONDITIONALLY, AND THAT REPLACED AN `if (this.marked.size)` GUARD ON 2026-09-03.
  // The guard existed so a plain view reset would not stomp a MEASUREMENT the user had just asked
  // for with "nothing selected" — but a measurement no longer exists apart from a selection, and
  // the one state the guard still protects is the stale one: unpick the last part and the readout
  // reads "60 × 40 mm · nothing selected" over an empty set, which a Reset must not leave standing.
  // A second statement for the measurement highlight went with the highlight itself.
  reset() {
    this.panZoom?.reset()
    this.clearMarks()
  }

  // `zoom`, `startPan`, `movePan`, `endPan`, `toUserSpace` and `setViewBox` LIVED HERE and are now
  // lib/svg_pan_zoom's — the letterbox conversion, the [span/500, span*4] clamp, the 3-screen-pixel
  // pan slop and the pointer capture, all unchanged. They moved so the Gerber stage could have the
  // same hands rather than a second copy of them (§14d).
  //
  // `this.view` WENT WITH THEM: every reader of it was one of those six methods, so keeping a
  // mirror here would be state written on every wheel tick and read by nothing. `this.home` stays
  // because the install needs it, and `this.svg` because `showPoster` still clears it and
  // measure_print_test.rb's Reset case reads the element's viewBox back through it. The handle is
  // `this.panZoom` — `reset`, `didPan`, `panning`, and `set`/`view` for a caller that ever needs
  // the numbers.

  setStatus(text) {
    if (this.hasDimsTarget) this.dimsTarget.textContent = text
  }
}
