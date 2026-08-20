import { Controller } from "@hotwired/stimulus"

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
//
// Lazy by design: nothing is fetched until Measure is clicked. The payload reaches 281 KB gzipped
// on the densest real files, and most pages are never measured.
const SVG_NS = "http://www.w3.org/2000/svg"

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

// Screen pixels of pointer travel before a drag counts as a pan rather than a click.
const PAN_SLOP_PX = 3

export default class extends Controller {
  // `name` IS REQUIRED, NOT COSMETIC. Stimulus silently ignores a data-*-value attribute the
  // controller does not declare, so `this.nameValue` is `undefined` until it appears here — no
  // error, no warning, just an empty filename on every printed sheet.
  static values = { url: String, name: String }
  static targets = ["stage", "dims", "fallback", "selectToggle", "paper", "printButton", "clearButton"]

  connect() {
    this.aborted = false
    this.selected = null
    this.hovered = null
    // THE PRINT SET. Membership is by IDENTITY on the payload's own shape objects, reached through
    // node.__shape — so nothing about the wire format has to change to give a contour an id.
    this.marked = new Set()
    this.nodeByShape = new Map()
    this.selecting = false
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
    this.selected = this.hovered = this.svg = null
    // AND THE PRINT SET WITH IT. Every leak here is silent, because the poster hides the whole
    // actions bar: a set left populated goes on being promised by the print button — and printed
    // — over shapes that are no longer marked, no longer drawn, and no longer even the objects
    // the next payload will hand out.
    this.marked.clear()
    this.nodeByShape.clear()
    this.selecting = false
    this.applySelecting()
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
    this.byObject = new Map()
    for (const s of payload.shapes) {
      if (!this.byObject.has(s.o)) this.byObject.set(s.o, [])
      this.byObject.get(s.o).push(s)
    }

    if (!payload.shapes.length) {
      this.setStatus("No measurable geometry in this file.")
      return
    }

    const svg = document.createElementNS(SVG_NS, "svg")
    const pad = Math.max(payload.job.w, payload.job.h) * 0.02
    this.home = [payload.job.x - pad, payload.job.y - pad,
                 payload.job.w + pad * 2, payload.job.h + pad * 2]
    this.setViewBox(svg, this.home)
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
    this.setStatus(`${payload.shapes.length} shapes · click one to measure`)
    this.bindInteractions(svg)
  }

  area(s) {
    return Math.max(s.b[2] - s.b[0], 0.01) * Math.max(s.b[3] - s.b[1], 0.01)
  }

  // A bitmap draws as a dashed placeholder: its base64 is excluded from the payload on purpose
  // (one real file is 1.45 MB as SVG and 0.1 KB as geometry), and a measuring view has no use
  // for the photo — only for the rectangle it occupies.
  contourNode(shape) {
    const node = document.createElementNS(SVG_NS, shape.k ? "polygon" : "polyline")
    const points = shape.p.map(([x, y]) => `${x},${y}`).join(" ")
    node.setAttribute("points", points)
    node.setAttribute("class", shape.i ? "measure-bitmap" : (shape.k ? "measure-contour" : "measure-contour measure-contour--open"))
    // LightBurn's own layer colour, sent by the server so the palette has ONE definition (see
    // LbrnGeometry#layer_colors).
    //
    // A PRESENTATION ATTRIBUTE, NOT node.style — and the difference is the whole highlight
    // mechanism. An inline style beats a stylesheet, so setting style.stroke here would make
    // .measure-contour--hover and --selected unable to recolour anything: clicking a contour would
    // change its width and nothing else. A presentation attribute sits BELOW every CSS rule in
    // the cascade, so the layer colour shows at rest and the highlight classes still win. For the
    // same reason .measure-contour must not declare a stroke of its own — a class rule would beat
    // this attribute and every layer would draw identically.
    if (!shape.i) node.setAttribute("stroke", this.colors[shape.c] || "#000000")
    node.__shape = shape
    if (shape.k || shape.i) return node

    // An open polyline has no interior to click and a hairline stroke to aim at. Group it with a
    // transparent fat twin so the hit area is finger-sized while the drawn line stays 1px.
    const group = document.createElementNS(SVG_NS, "g")
    const hit = document.createElementNS(SVG_NS, "polyline")
    hit.setAttribute("points", points)
    hit.setAttribute("class", "measure-contour--hit")
    hit.__shape = shape
    hit.__visible = node // so hover/selection colours the drawn line, not the invisible twin
    group.appendChild(hit)
    group.appendChild(node)
    // So draw() can resolve a group to the line it should style, the same way styleNode() does.
    group.__visible = node
    return group
  }

  bindInteractions(svg) {
    svg.addEventListener("pointermove", (e) => this.hover(e))
    svg.addEventListener("pointerleave", () => this.clearHover())
    svg.addEventListener("click", (e) => this.pick(e))
    svg.addEventListener("wheel", (e) => this.zoom(e), { passive: false })
    svg.addEventListener("pointerdown", (e) => this.startPan(e))
    svg.addEventListener("pointermove", (e) => this.movePan(e))
    svg.addEventListener("pointerup", (e) => this.endPan(e))
    svg.addEventListener("pointercancel", (e) => this.endPan(e))
  }

  // `event.target` IS NOT TRUSTWORTHY ON A CLICK HERE, AND THE PAN'S POINTER CAPTURE IS WHY.
  // `startPan` captures the pointer on the <svg> so a drag that wanders off the element keeps
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
  // line; closed contours are their own hit target and have none.
  styleNode(node) {
    return node.__visible || node
  }

  hover(event) {
    if (this.panOrigin) return
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

  pick(event) {
    if (this.didPan) { this.didPan = false; return }
    const node = this.shapeAt(event)
    if (!node) return

    if (this.selected) this.styleNode(this.selected).classList.remove("measure-contour--selected")
    this.selected = node
    this.styleNode(node).classList.add("measure-contour--selected")

    const shape = node.__shape
    const siblings = this.byObject.get(shape.o) || [shape]
    // Alt-click widens to the whole <Shape> object — every contour the parser gave the same
    // object id, which for a Text is its entire rendered outline rather than one letter.
    const useObject = event.altKey && siblings.length > 1

    if (this.selecting) {
      this.toggleMarks(useObject ? siblings : [shape])
      // BOTH HALVES, because picking parts and learning their sizes are one gesture: a mode that
      // silenced the measurement would make you leave it to check a size.
      const size = useObject ? this.dims(this.unionOf(siblings)) : this.sizeLabel(shape)
      this.setStatus(`${size} · ${this.selectionStatus()}`)
      return
    }
    this.setStatus(useObject ? this.objectLabel(siblings) : this.contourLabel(shape, siblings))
  }

  toggleSelect() {
    this.selecting = !this.selecting
    this.applySelecting()
    this.setStatus(this.selecting ? this.selectionStatus() : "click a contour to measure")
  }

  // ONE DEFINITION OF WHAT THE TOGGLE LOOKS LIKE IN A GIVEN STATE, because showPoster() leaves
  // select mode too. Resetting only `this.selecting` and the cursor class there — the obvious
  // version — leaves the button reading "Done selecting" with aria-pressed="true" over a
  // controller that is no longer selecting. Invisible while the poster is up (.measure-actions is
  // display:none without --ready) and plainly wrong the moment Measure is clicked again.
  applySelecting() {
    this.element.classList.toggle("measure-view--selecting", this.selecting)
    this.selectToggleTarget.setAttribute("aria-pressed", String(this.selecting))
    this.selectToggleTarget.textContent = this.selecting ? "Done selecting" : "Select parts"
  }

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

  clearMarks() {
    for (const shape of this.marked) {
      this.nodeByShape.get(shape)?.classList.remove("measure-contour--marked")
    }
    this.marked.clear()
    this.refreshPrintBar()
    this.setStatus(this.selectionStatus())
  }

  selectionStatus() {
    const n = this.marked.size
    if (!n) return "nothing selected · Print all prints the whole file"
    return `${n} part${n === 1 ? "" : "s"} · ${this.dims(this.unionOf([...this.marked]))}`
  }

  // NO `hasPrintButtonTarget` GUARD, DELIBERATELY, and the plan's draft had one. All six controls
  // live in ONE always-rendered <span class="measure-actions">, and each of the three callers —
  // toggleMarks, clearMarks, showPoster — is reachable only once a button in that span has been
  // clicked (toggleMarks through pick, which marks nothing until toggleSelect turned the mode on).
  // showPoster also touches selectToggleTarget one line earlier, so a guard here would answer a
  // question the line above already answered. And in the one future it was written for — a partial
  // that omits the bar — nothing reaches this method at all. A guard that cannot fail asserts a
  // condition that does not exist.
  refreshPrintBar() {
    const n = this.marked.size
    this.printButtonTarget.textContent = n ? `Print ${n} part${n === 1 ? "" : "s"}` : "Print all"
    this.clearButtonTarget.hidden = n === 0
  }

  contourLabel(shape, siblings) {
    let label = this.sizeLabel(shape)
    if (siblings.length > 1) {
      label += ` · part of a ${siblings.length}-contour object (⌥ for ${this.dims(this.unionOf(siblings))})`
    }
    return label
  }

  objectLabel(siblings) {
    return `${this.dims(this.unionOf(siblings))} · whole object, ${siblings.length} contours`
  }

  // ⌀ only when the server said so. Circularity is decided server-side, from full-resolution
  // points, so the client never re-derives a measurement from the thinned drawing points.
  sizeLabel(shape) {
    return shape.d != null ? `⌀${this.mm(shape.d)} mm` : this.dims(shape.b)
  }

  dims(box) {
    return `${this.mm(box[2] - box[0])} × ${this.mm(box[3] - box[1])} mm`
  }

  unionOf(shapes) {
    return [
      Math.min(...shapes.map((s) => s.b[0])), Math.min(...shapes.map((s) => s.b[1])),
      Math.max(...shapes.map((s) => s.b[2])), Math.max(...shapes.map((s) => s.b[3]))
    ]
  }

  mm(n) {
    return (Math.round(n * 10) / 10).toLocaleString()
  }

  reset() {
    if (this.svg && this.home) this.setViewBox(this.svg, this.home)
  }

  // Zoom about the cursor, so the feature under the pointer stays under it.
  zoom(event) {
    if (!this.svg) return
    event.preventDefault()
    const [x, y, w, h] = this.view
    const factor = event.deltaY > 0 ? 1.15 : 1 / 1.15
    const span = Math.max(this.home[2], this.home[3])
    const nextW = Math.min(Math.max(w * factor, span / 500), span * 4)
    const nextH = h * (nextW / w)

    const p = this.toUserSpace(event)
    this.setViewBox(this.svg, [
      p.x - (p.x - x) * (nextW / w), p.y - (p.y - y) * (nextH / h), nextW, nextH
    ])
  }

  startPan(event) {
    if (event.button !== 0 || !this.svg) return
    this.panOrigin = this.toUserSpace(event)
    this.panScreen = { x: event.clientX, y: event.clientY }
    this.didPan = false
    this.svg.setPointerCapture(event.pointerId)
    this.svg.classList.add("is-panning")
  }

  movePan(event) {
    if (!this.panOrigin) return
    // THE SLOP IS IN SCREEN PIXELS, NOT USER UNITS, and that is not interchangeable: zoomed in,
    // one mm is many pixels, so a user-space threshold calls an ordinary click a drag and
    // silently swallows the selection the user was trying to make.
    if (Math.hypot(event.clientX - this.panScreen.x, event.clientY - this.panScreen.y) > PAN_SLOP_PX) {
      this.didPan = true
    }
    const p = this.toUserSpace(event)
    const [x, y, w, h] = this.view
    this.setViewBox(this.svg, [x + (this.panOrigin.x - p.x), y + (this.panOrigin.y - p.y), w, h])
  }

  endPan(event) {
    if (!this.panOrigin) return
    this.panOrigin = null
    this.svg.releasePointerCapture?.(event.pointerId)
    this.svg.classList.remove("is-panning")
  }

  // Screen px -> the SVG's own user units (mm), which is what viewBox maths needs.
  toUserSpace(event) {
    const rect = this.svg.getBoundingClientRect()
    const [x, y, w, h] = this.view
    // preserveAspectRatio="xMidYMid meet" letterboxes: the scale is the SMALLER of the two,
    // and the unused axis is centred. Ignoring that makes the cursor drift on non-square files.
    const scale = Math.min(rect.width / w, rect.height / h)
    const offX = (rect.width - w * scale) / 2
    const offY = (rect.height - h * scale) / 2
    return {
      x: x + (event.clientX - rect.left - offX) / scale,
      y: y + (event.clientY - rect.top - offY) / scale
    }
  }

  setViewBox(svg, [x, y, w, h]) {
    svg.setAttribute("viewBox", `${x} ${y} ${w} ${h}`)
    this.view = [x, y, w, h]
  }

  setStatus(text) {
    if (this.hasDimsTarget) this.dimsTarget.textContent = text
  }
}
