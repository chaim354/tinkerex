import { Controller } from "@hotwired/stimulus"
import { PAPERS, printSheets, sheetDocuments } from "lib/print_sheet"
import { exportSvg } from "lib/export_svg"
import { postJSON, uploadChunkFile, uploadPortFile } from "lib/chunk_upload"
import { SVG_NS, shapeElement, unionBox } from "lib/shape_svg"
import { installPanZoom } from "lib/svg_pan_zoom"

// Measure view: click a contour, read its size in mm or inches.
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

// THE UNIT A LENGTH IS WRITTEN IN, and ONLY written in. The payload is millimetres and stays
// millimetres: every number is converted at the last step, in `length()`, so nothing upstream of
// a label — the bbox, the ⌀, the union, the page geometry — ever holds an inch. Remembered across
// visits for the paper's reason: a maker who works in inches does so on every file.
//
// `places` IS THE DISPLAY PRECISION, AND THE INCH FIGURE IS NOT FINER THAN THE DATA. The payload
// rounds at 0.01 mm (Geometry::PRECISION); 0.001 in is 0.0254 mm, so three places in inches still
// says less than the server measured, as 0.1 mm does.
//
// THE SVG EXPORT AND THE PRINT SHEET'S SCALE ARE NOT UNITS OF DISPLAY and do not read this:
// `width="{w}mm"` over a viewBox is the whole scale mechanism of both (§14h), so an inch toggle
// reaching them would change the size of a file somebody cuts. The sheet's size LABELS do follow
// it, through the injected `sizeLabel` — the paper and the readout must not disagree (§14h).
const UNITS = {
  mm: { label: "mm", perMm: 1, places: 1 },
  in: { label: "in", perMm: 1 / 25.4, places: 3 },
}
const UNIT_KEY = "measure.unit"
const DEFAULT_UNIT = "mm"

export default class extends Controller {
  // `name` IS REQUIRED, NOT COSMETIC. Stimulus silently ignores a data-*-value attribute the
  // controller does not declare, so `this.nameValue` is `undefined` until it appears here — no
  // error, no warning, just an empty filename on every printed sheet.
  static values = {
    url: String, name: String,
    portWritable: Boolean, createUrl: String, beginUrl: String, finalizeUrl: String,
    parentNodeId: String,
    // WHERE A SAVED EXPORT CAME FROM (stage 4, S4-8). Both are rendered only inside the partial's
    // `save` branch, so a visitor's page declares neither and `hasSourceNodeIdValue` is false —
    // which is what `recordSources` asks before it posts anything.
    sourceNodeId: String, linkUrl: String
  }
  // EVERY VALUE HERE IS READ. Stimulus silently ignores a `data-*-value` the controller does not
  // declare — the trap `name` records above — and the converse costs nothing but is still a lie
  // about what this surface needs, so a value that no method reads does not get declared.
  static targets = ["stage", "dims", "fallback", "paper", "printButton", "svgButton",
                    "savePrintButton", "saveSvgButton", "unitButton"]

  // ONE LOAD GENERATION FOR THE LIFE OF THIS CONTROLLER, and the one owner of the stage: a load
  // paints only while its own number is the latest. Set in `initialize`, never in `connect`,
  // because Stimulus hands a re-attached element the SAME controller. A count restarted on
  // reconnect would hand a new load the number a load from before the disconnect already holds,
  // and the older one could then paint.
  initialize() {
    this.generation = 0
  }

  connect() {
    // READ HERE, NOT IN draw(), because sizeLabel() has callers that never go through draw():
    // measure_print_test.rb drives print() on a hand-built `allShapes`, and an undefined unit there
    // is a TypeError out of the print. `storedUnit` cannot throw, so this is safe where
    // populatePaper's read had to be moved below bindInteractions.
    this.unit = this.storedUnit()
    this.refreshUnitToggle()
    // THE READOUT ON SCREEN, AS THE FUNCTION THAT WROTE IT — or null for a line with no length in
    // it. Flipping the unit re-runs it, so "60 × 40 mm" cannot sit beside a toggle reading "in".
    this.readout = null
    // AT REST, WHATEVER THE MARKUP SAYS — gerber_controller.js's rule, and the reason
    // `measure-view--ready` can be trusted. A Turbo Drive Back restores the page from a snapshot
    // taken WITH the view open: the class, the drawn SVG, the `--marked` contours, "Print 1 part"
    // and the readout. It then connects this fresh controller, which holds none of the shapes, the
    // SVG or the pan handle behind them. Left alone, that stage was dead while it looked live:
    // pan, zoom and clicks did nothing, Print promised a part it no longer held, and Reset threw
    // out of restingStatus(). Resting puts the poster back, and the drawing is one click away as
    // it was. measure_print_test.rb drives the Back.
    this.rest()
  }

  // A PAGE THAT GOES AWAY OWNS NOTHING, so the bump is the whole of this. The poll is NOT cancelled
  // here. A cleared timer would leave the shared fetch pending forever, and a re-attached
  // controller would then join a promise that never settles. The poll notices the element left
  // the document and stops itself (fetchPayload).
  disconnect() {
    this.generation++
  }

  // "Measure". ONE IN-FLIGHT FETCH, SHARED, AND A DRAW ONLY FOR THE LOAD THAT STILL OWNS THE STAGE:
  // gerber_controller.js's pair, for the same two hazards. The launch button stays clickable until
  // draw() reveals the stage, so a second click while the payload is on its way is an ordinary
  // gesture. It used to start a second poll and a second download (up to 1.3 MB gzipped, §14h), and
  // to draw twice. The later draw replaced the SVG the user was already selecting on, and the
  // selection survived in `marked`, so the bar read "Print 1 part" over a stage with nothing
  // highlighted. Now the second click joins the first fetch. The first load sees it no longer owns
  // the stage and paints nothing, so the view is drawn once.
  //
  // A SUPERSEDED LOAD REPORTS NOTHING EITHER. With the fetch shared, its rejection reaches every
  // load that joined it, and only the one that owns the stage may put the reason on screen.
  async load() {
    const gen = ++this.generation
    this.setStatus("Loading geometry…")
    try {
      this.pending ||= this.fetchPayload().finally(() => { this.pending = null })
      const payload = await this.pending
      if (gen !== this.generation || !payload) return
      this.draw(payload)
    } catch (e) {
      if (gen !== this.generation) return
      console.warn("[measure] keeping the thumbnail:", e)
      this.setStatus(e.message || "Could not load geometry.")
    }
  }

  // "✕ Image". `generation++` so nothing still in flight can draw after the dismissal and reopen
  // the view.
  showPoster() {
    this.generation++
    this.rest()
  }

  // THE ONE WAY BACK TO THE POSTER: `connect()` and ✕ Image both come through here. It drops
  // everything a drawing owns, so the controller holds shapes exactly while a drawing is on the
  // stage. `--ready` comes off, and only draw() puts it back.
  rest() {
    this.element.classList.remove("measure-view--ready")
    this.stageTarget.replaceChildren()
    this.setStatus("")
    this.hovered = this.svg = this.allShapes = null
    // THE SELECTION, AND SINCE 2026-09-03 THE ONLY SELECTION STATE THERE IS. Membership is by
    // IDENTITY on the payload's own shape objects, reached through node.__shape — so nothing about
    // the wire format has to change to give a contour an id.
    //
    // IT WAS TWO STATES UNTIL THEN, AND THAT IS WHAT THE USER ASKED TO COLLAPSE: a transient
    // `selected` contour (the measurement highlight, red) beside this print set (blue), which
    // could only be added to while a "Select parts" MODE was on. There is no mode now — every
    // click marks — and one colour answers the one question, which is why `selecting`, `selected`
    // and the toggle target are absent rather than merely unused. See §14h.
    //
    // EMPTIED HERE, AND draw() DOES NOT EMPTY IT AGAIN. A drawing always starts from the empty set
    // this leaves. The launch button is the one way to a load, and it shows only while `--ready`
    // is off, which is from here until the next draw(). So a second drawing has to come through
    // ✕ Image, and therefore through here. A double click on the button still draws once, because
    // the generation in load() lets only the latest load paint. With nothing drawn there is
    // nothing to click, so nothing can be selected in between. A leak here would be silent: a set
    // left populated goes on being promised by the print button, and printed, over shapes that
    // are no longer marked, no longer drawn, and no longer even the objects the next payload will
    // hand out.
    this.marked = new Set()
    this.nodeByShape = new Map()
    this.refreshPrintBar()
  }

  // Poll the endpoint until it reports ready, then fetch the payload from the blob URL it names.
  //
  // ONE POLL AT A TIME, because load() shares it. It stops itself once the view has left the
  // document. Resolving with null there settles the shared fetch, so a controller re-attached
  // later starts a fresh one rather than joining a poll nobody is running.
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
      if (!this.element.isConnected) return null
    }
    throw new Error("Still generating — reload to check.")
  }

  sleep(ms) {
    return new Promise((resolve) => { setTimeout(resolve, ms) })
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
    // bottom of this method — it sets `home` as it installs. That runs AFTER `replaceChildren` has
    // put the element in the document, and it is still fine, because nothing between here and
    // there yields to the event loop: the browser cannot paint a viewBox-less frame in between.
    // An `await` inserted anywhere in this method would break that, which is why there is none.
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
    // AND THE PRINT BAR, LAST, written from the selection this drawing starts with. Since
    // 2026-10-19 (F-S09-1) that is the empty set rest() leaves (see there), so this writes the
    // words rest() already wrote. What keeps the ERB's at-rest literals from drifting is rest() on
    // connect(), not this line: the controller rewrites the bar the moment it connects, so the
    // controller, not the template, is the one definition of the bar at rest. Until then this call
    // was the only controller write of that bar. A partial reading "Print" stayed green with it
    // and went red in five places without it, and the argument that draw() could not run twice
    // without ✕ Image rested on the launch button being display:none. A double click ran it
    // twice. The generation in load() is what makes that argument true now.
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

  // `Object.hasOwn`, NOT `UNITS[saved] ?` the way populatePaper asks PAPERS: a stored
  // "constructor" or "toString" answers truthy off Object.prototype, and the unit would become a
  // function with no `perMm`, printing NaN in every label. The try is for a blocked or partitioned
  // storage context, which throws on READ — a remembered preference must not cost measuring.
  storedUnit() {
    try {
      const saved = localStorage.getItem(UNIT_KEY)
      return Object.hasOwn(UNITS, saved) ? saved : DEFAULT_UNIT
    } catch (e) {
      return DEFAULT_UNIT
    }
  }

  setUnit({ params: { unit } }) {
    if (!Object.hasOwn(UNITS, unit) || unit === this.unit) return
    this.unit = unit
    try {
      localStorage.setItem(UNIT_KEY, unit)
    } catch (e) {
      // The choice still holds for this page; it just will not be remembered.
      console.warn("[measure] could not remember the unit:", e)
    }
    this.refreshUnitToggle()
    if (this.readout) this.setReadout(this.readout)
  }

  // THE ERB RENDERS `mm` PRESSED AT REST and this rewrites it from the stored choice before the bar
  // is ever shown (`.measure-actions` is display:none until --ready). NO `hasUnitButtonTarget`
  // GUARD, for refreshPrintBar's reason: both buttons live in the always-rendered actions span, on
  // the owner's page and a visitor's alike.
  refreshUnitToggle() {
    for (const button of this.unitButtonTargets) {
      const on = button.dataset.measureUnitParam === this.unit
      button.classList.toggle("active", on)
      button.setAttribute("aria-pressed", String(on))
    }
  }

  print() {
    const shapes = this.targetShapes()
    // NOT DEAD, BUT ONLY REACHABLE BY DRIVING THIS METHOD DIRECTLY. `allShapes` is null whenever
    // no drawing is on the stage: rest() clears it, and draw() sets it before it adds --ready, the
    // class that reveals this button. rest() also runs on connect, so a page restored from Turbo's
    // snapshot cannot arrive with the class and no shapes behind it. It could until 2026-10-19,
    // and then "the button is display:none" was not enough. What the guard buys is the difference
    // between doing nothing and putting a raw TypeError from buildSheets into the readout as the
    // answer to a button press. Pinned by a test that calls print() directly, because nothing else
    // can.
    if (!shapes || !shapes.length) return
    try {
      // BOTH ARGUMENTS ARE METHODS, NOT LITERALS, SINCE STAGE 4 S4-3. `savePrint()` renders the
      // SAME sheets through the same renderSheet, so a paper expression and a meta hash spelled
      // out here would be two copies of each — the drift `targetShapes()`/`targetNoun()` already
      // exist to prevent for the target set, in a file that records having been bitten by it.
      printSheets(shapes, this.sheetPaper(), this.sheetMeta())
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
    // The same guard as print()'s, for the same state: `allShapes` is null whenever nothing is
    // drawn, and only a drawing reveals this button.
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

  // --- Save to library (stage 4, S4-3) ---------------------------------------------------
  //
  // THE SAME BYTES THE DOWNLOAD BUILDS, THROUGH THE SAME TWO DOORS EVERY OTHER UPLOAD USES.
  // `exportSvg` and `sheetDocuments` are the pure builders; this half owns the Blob, the name and
  // the door — the split print_sheet.js draws between renderSheet and buildPrintFrame, and
  // export_svg.js between the document and the anchor.
  //
  // NOT Maker::Addons::LibraryOutput, WHICH WAS THE OTHER CANDIDATE. That is the ADDON save door:
  // it takes bytes SERVER-side and calls the port's own put_chunk, which is right for a generator
  // whose output is produced in Rails and has no client to presign for. Here the browser already
  // holds the bytes, so the upload doors keep them out of Rails entirely on chunk_remote (§15) and
  // give share/s3 the same multipart write they already use.
  //
  // THE NAME IS THE SOURCE'S BASE NAME PLUS THE SAME SUFFIX THE DOWNLOAD USES. Two names for one
  // set of bytes is two answers to one question: `downloadSvg` writes `<base>-parts.svg`, so this
  // does too, and a maker who downloaded first and saved second gets one file, not two spellings.
  saveSvg() {
    const shapes = this.targetShapes()
    if (!shapes || !shapes.length) return
    const base = this.nameValue.replace(/\.[^.]+$/, "")
    this.saveAll([ { name: `${base}-parts.svg`, body: exportSvg(shapes, { colors: this.colors }) } ],
                 this.saveSvgButtonTarget)
  }

  // ONE FILE PER SHEET, AND THE PLURAL CASE IS NOT AN EDGE CASE. A to-scale plan that needs four
  // tiles IS four pages — that tiling is the whole point of the sheet — so collapsing them into one
  // document would throw away what the maker asked for. A single sheet keeps the plain name so the
  // common case reads as one thing.
  savePrint() {
    const shapes = this.targetShapes()
    if (!shapes || !shapes.length) return
    const base = this.nameValue.replace(/\.[^.]+$/, "")
    let bodies
    try {
      bodies = sheetDocuments(shapes, this.sheetPaper(), this.sheetMeta())
    } catch (e) {
      // buildSheets' refusals (nothing selected, MAX_SHEETS) reach the readout, the way print()'s
      // do — they throw before any file exists, so a swallowed message is a button that does
      // nothing whatsoever. AND IT LOGS, because this catch cannot tell a refusal from a bug.
      console.warn("[measure] sheet save refused:", e)
      return this.setStatus(e.message)
    }
    const files = bodies.map((body, i) => ({
      name: bodies.length === 1 ? `${base}-print.svg`
                                : `${base}-print-${i + 1}of${bodies.length}.svg`,
      body
    }))
    this.saveAll(files, this.savePrintButtonTarget)
  }

  // ONE UPLOAD LOOP FOR BOTH BUTTONS, sequential rather than parallel: the doors are the same doors
  // an ordinary upload uses, and a browser firing four concurrent multipart POSTs at a Puma pool is
  // the shape §14e records as a stall. A file that refuses (a name already taken on share/s3 — the
  // port's clobber refusal, 422) is REPORTED BY NAME and stops the run, because the sheets after it
  // would collide identically and four identical messages say nothing the first did not.
  async saveAll(files, button) {
    const previous = button.textContent
    button.disabled = true
    button.textContent = "Saving…"
    try {
      let last = null
      const saved = []
      for (const file of files) {
        last = await this.uploadOne(new File([ file.body ], file.name, { type: "image/svg+xml" }))
        saved.push(last.nodeId)
      }
      await this.recordSources(saved)
      // THE SERVER'S OWN SENTENCE WHEN IT HAS ONE. Both doors answer with `notice`, built by
      // ProjectFolderIntake — so when the project-folder sweep could not file the save into its
      // category folder because a file of that name is already there, the maker is told, in the
      // wording every other upload door uses. Otherwise: what was written, and how many.
      this.setStatus(last?.notice || `Saved ${files.length === 1 ? files[0].name : `${files.length} sheets`}.`)
    } catch (e) {
      console.warn("[measure] save refused:", e)
      this.setStatus(e.message)
    } finally {
      button.disabled = false
      button.textContent = previous
    }
  }

  // THE LINEAGE, WRITTEN BY THE SAVE THAT CREATED IT (stage 4, S4-8; story 3.2). Everything this
  // view saves is DERIVED from the file being measured, so the save records that as it lands —
  // unasked, which is the feature (plan decision 2); the Connected panel's `×` on the export's own
  // page is what withdraws it again.
  //
  // A SECOND REQUEST RATHER THAN A PARAMETER ON THE UPLOAD DOORS. Those two doors serve every
  // uploader in the app, and one extra POST to the endpoint the file page's own "This came from…"
  // control already uses is smaller than a link concern threaded through two general write paths.
  //
  // IT CANNOT FAIL THE SAVE, AND THAT IS DELIBERATE. The bytes are already in the library; a link
  // that did not land is repairable with the hand control on that very file's page, so this logs
  // and says nothing. Reporting it would tell a maker their save failed when it did not — which is
  // why the try/catch is INSIDE the loop rather than around the `await` in saveAll, where a throw
  // would reach saveAll's own catch and overwrite the success sentence with an error.
  //
  // "ALREADY LINKED" IS A SUCCESS, WITH NOTHING TO DO. Files::LinksController rescues the unique
  // index's RecordNotUnique into `head :ok` for a JSON request — a 2xx — so `postJSON` returns
  // rather than throwing, and re-saving one export over another lands here silently.
  async recordSources(nodeIds) {
    if (!this.hasSourceNodeIdValue || !this.hasLinkUrlValue) return
    for (const id of nodeIds) {
      if (!id) continue
      try {
        await postJSON(this.linkUrlValue.replace("__ID__", encodeURIComponent(id)),
                       { kind: "derived_from", other_node_id: this.sourceNodeIdValue })
      } catch (e) {
        console.warn("[measure] could not record where this came from:", e)
      }
    }
  }

  // THE TWO-DOOR CHOICE, MADE THE WAY importer_controller.js MAKES IT. `port_writable` is the
  // deployment's answer to "which door do bytes go in", never "can this deployment take uploads" —
  // chunk_remote takes uploads all day, through the flow on the false branch (§14a).
  uploadOne(file) {
    return this.portWritableValue
      ? uploadPortFile(file, { createUrl: this.createUrlValue, parentNodeId: this.parentNodeIdValue })
      : uploadChunkFile(file, { beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue,
                                parentNodeId: this.parentNodeIdValue })
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
    //
    // A READOUT, NOT A STATUS: the line is kept as the function that composes it, so the unit
    // toggle can rewrite it in place. Both halves carry lengths, and both are re-read at that
    // moment — the selection summary is the set as it stands, which is what it said when written.
    this.setReadout(() => {
      const size = useObject ? this.dims(unionBox(siblings)) : this.contourLabel(shape, siblings)
      return `${size} · ${this.selectionStatus()}`
    })
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
  // NO `allShapes` GUARD AROUND `restingStatus()`, DELIBERATELY. Both callers act on a drawing
  // THIS controller made. `pick` is bound to the SVG that draw() built, and Reset is in the bar
  // that --ready reveals. Only draw() adds that class, after recording `allShapes`. rest() takes
  // it off as it clears them, and runs on connect, so a Turbo-restored snapshot cannot keep the
  // class over a controller with no shapes. Until 2026-10-19 one could: this argument then rested
  // on "Reset is display:none", and Reset threw here after a Back. A guard that cannot fail
  // asserts a condition that does not exist, which is refreshPrintBar()'s argument about its
  // targets.
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

  // THE SHEET FURNITURE'S FACTS, IN ONE PLACE. `print()` and `savePrint()` render the SAME sheets
  // and must not disagree about the header, the date or how a size is written — the one-definition
  // rule targetShapes()/targetNoun() already keeps for the target set.
  //
  // sizeLabel READS `d` AND `b`, THE SERVER'S FULL-RESOLUTION NUMBERS, NEVER `p` (the THINNED
  // drawing points). Re-deriving a size from those under-reports every curve and loses the ⌀
  // outright, because this side has no circularity test (§14h). Measured: the mutation prints
  // "10 × 10 mm" where "⌀10 mm" belongs.
  // THE PAPER IN FORCE, WITH ITS FALLBACK — the belt `print()` carried inline until S4-3, moved
  // here rather than copied into `savePrint()`. It is reachable in exactly one state: an
  // unpopulated select answers `value === ""`, which is no key in PAPERS. Without the `||`,
  // buildSheets gets `undefined` for its paper and dies in contentBox, so a deployment that ever
  // lost populatePaper would lose Print AND Save sheet rather than degrading to the default.
  sheetPaper() {
    return PAPERS[this.paperTarget.value] || PAPERS[DEFAULT_PAPER]
  }

  sheetMeta() {
    return {
      name: this.nameValue,
      // LOCAL, NOT UTC. `toISOString()` stamps an evening print in the Americas with TOMORROW's
      // date, on a sheet whose header exists so a page found on a bench next week can be trusted.
      date: new Date().toLocaleDateString("en-CA"),
      sizeLabel: (shape) => this.sizeLabel(shape),
    }
  }

  // NO `hasPrintButtonTarget` GUARD, DELIBERATELY, and the plan's draft had one. SIX of the eight
  // controls — the mm/in toggle, the paper select, Print, Download SVG, Reset and ✕ Image — live in ONE
  // always-rendered <span class="measure-actions">, so those targets exist whenever this controller
  // is connected. A guard that cannot fail asserts a condition that does not exist.
  //
  // THE TWO SAVE TWINS ARE THE EXCEPTION SINCE STAGE 4, S4-5, AND THEIR GUARDS BELOW ARE REAL. This
  // comment used to say the same "cannot fail" of them; that stopped being true the moment a SECOND
  // page rendered this partial. `files/viewers/_measure.html.erb` takes a `save:` local and a
  // VISITOR's public file page passes false — there is no library for an export to land in and no
  // session to write it with — so those two targets are genuinely absent there, and an unguarded
  // `this.saveSvgButtonTarget` here throws "Missing target element", which would break Measure on
  // that page entirely. That was measured against the partial, not reasoned, when the throw came
  // out of draw(). Since rest() calls this method, the same line now throws out of connect(). The
  // callers are draw(), toggleMarks, clearMarks and rest().
  //
  // AND SINCE 2026-10-19 IT RUNS ON EVERY CONNECT, through rest() (F-S09-1). That settles what this
  // comment used to argue in two halves. toggleMarks and clearMarks need a drawing, and draw()
  // runs off the launch button, so the old version could not say that nothing reaches this
  // method without a click. Now something always does: every page that renders the partial calls
  // it before anything is drawn. The clause "in the one future it was written for, a partial that
  // omits the bar, nothing reaches this method at all" was deleted rather than relied on, and
  // stays deleted: such a partial breaks connect() itself. The answer then is that the partial
  // declares the controls, not that four methods each grow a guard.
  // THE LABEL ALWAYS NAMES THE TARGET IN FORCE, and it can no longer do otherwise: the noun comes
  // from `targetNoun()` and the shapes `print()` acts on from `targetShapes()`, so the two halves
  // of the claim are one definition rather than two spellings kept in step by a comment. Two
  // wordings survive the merge — "Print all" and "Print 3 parts"; "Print selected" went with the
  // middle arm on 2026-09-03, since a selected contour IS a one-part set now.
  refreshPrintBar() {
    const noun = this.targetNoun()
    this.printButtonTarget.textContent = `Print ${noun}`
    // THE SVG BUTTON'S TEXT DOES NOT MOVE, SO ITS ACCESSIBLE NAME MUST. All FOUR are written here
    // since stage 4, S4-3 (it was two), from one targetNoun(), so no two of these buttons can come
    // to describe different sets. Its
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
    // THE SAVE TWINS TRACK THE SAME TARGET. Four labels, one targetNoun(), so a button can never
    // describe a set a sibling does not act on; the ERB's at-rest literals are these same strings
    // with `noun` = "all", which is what makes them drift together or not at all.
    if (this.hasSaveSvgButtonTarget) {
      const svgSave = `Save ${noun} as SVG in the library`
      this.saveSvgButtonTarget.setAttribute("aria-label", svgSave)
      this.saveSvgButtonTarget.setAttribute("title", svgSave)
    }
    if (this.hasSavePrintButtonTarget) {
      const sheetSave = `Save ${noun} as a print sheet in the library`
      this.savePrintButtonTarget.setAttribute("aria-label", sheetSave)
      this.savePrintButtonTarget.setAttribute("title", sheetSave)
    }
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
    return shape.d != null ? `⌀${this.length(shape.d)} ${UNITS[this.unit].label}` : this.dims(shape.b)
  }

  dims(box) {
    return `${this.length(box[2] - box[0])} × ${this.length(box[3] - box[1])} ${UNITS[this.unit].label}`
  }

  // `unionOf` LIVED HERE AND WAS BYTE-IDENTICAL TO print_sheet's `unionBox`. The exporter would
  // have been a third copy, so the one definition moved to lib/shape_svg and both import it.

  // MILLIMETRES IN, THE CHOSEN UNIT OUT — the one place a payload number becomes text. It was
  // `mm(n)`, rounding to 0.1 and leaning on toLocaleString's DEFAULT of three fraction digits;
  // `maximumFractionDigits` is explicit now because inches use all three, and a fourth place
  // added to UNITS would otherwise be rounded away here without a word.
  length(mm) {
    const { perMm, places } = UNITS[this.unit]
    const scale = 10 ** places
    return (Math.round(mm * perMm * scale) / scale).toLocaleString(undefined, { maximumFractionDigits: places })
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
  // because the install needs it, and `this.svg` because `rest` still clears it and
  // measure_print_test.rb's Reset case reads the element's viewBox back through it. The handle is
  // `this.panZoom` — `reset`, `didPan`, `panning`, and `set`/`view` for a caller that ever needs
  // the numbers.

  // EVERY plain status drops the kept readout, so the unit toggle can only ever rewrite the line
  // that is actually on screen — never resurrect a measurement over "Saved sample-parts.svg." or
  // a refusal that replaced it.
  setStatus(text) {
    this.readout = null
    if (this.hasDimsTarget) this.dimsTarget.textContent = text
  }

  setReadout(compose) {
    this.setStatus(compose())
    this.readout = compose
  }
}
