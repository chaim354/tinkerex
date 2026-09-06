// ONE viewBox PAN/ZOOM FOR EVERY SVG STAGE — the Measure view's, extracted so the Gerber stage
// could have the same hands without a second copy of the maths (§14d's "a verb more than one
// controller performs gets a named service", the JS way). Wheel zooms about the cursor, a drag
// pans, two pointers pinch, `reset()` returns to `home`.
//
// EVERYTHING IS IN THE SVG'S OWN USER UNITS, converted from screen pixels through the element's
// letterbox: `preserveAspectRatio="xMidYMid meet"` scales by the SMALLER axis ratio and centres the
// other, and ignoring that makes the cursor drift on a non-square drawing (measure_controller.js
// learned this first, on files that are rarely square). Both callers set that attribute on the
// element they hand over, so the maths below is not making an assumption it cannot see.
//
// THE PAN SLOP IS SCREEN PIXELS, NOT USER UNITS, and the two are not interchangeable: zoomed in,
// one mm is many pixels, so a user-space threshold calls an ordinary click a drag and silently
// swallows the selection the user was trying to make. That is why `didPan()` exists at all —
// Measure's click handler asks it whether the gesture that just ended was a pan.
//
// `home` is the fit viewBox, `[x, y, w, h]`. Zoom is bounded to [span/500, span*4] of the larger
// home dimension, so nobody zooms into a single trace's pixel or out to a dot.
//
// THE POINTER IS CAPTURED ON THE ELEMENT, which has a consequence beyond keeping a drag alive when
// the cursor wanders off: a captured pointer retargets its own compatibility mouse events, so
// `click` is dispatched at the <svg> rather than at whatever was under the cursor. Measure's
// `shapeAt` is written for that and says so at length; a new caller that reads `event.target` on a
// click will find it useless for the same reason.
const PAN_SLOP_PX = 3
const ZOOM_STEP = 1.15

export function installPanZoom(svg, { home, onChange = null } = {}) {
  let view = null
  let panOrigin = null, panScreen = null, didPan = false
  const pointers = new Map()   // pointerId -> { x, y } in screen px, for pinch
  let pinchStart = null        // { dist, view, centre } at the moment the second finger landed

  const span = () => Math.max(home[2], home[3])

  function setViewBox([ x, y, w, h ]) {
    view = [ x, y, w, h ]
    svg.setAttribute("viewBox", `${x} ${y} ${w} ${h}`)
    onChange?.(view)
  }

  // Screen px -> user units (see the header for why the letterbox is part of this).
  function toUserSpace(clientX, clientY) {
    const rect = svg.getBoundingClientRect()
    const [ x, y, w, h ] = view
    const scale = Math.min(rect.width / w, rect.height / h)
    const offX = (rect.width - w * scale) / 2
    const offY = (rect.height - h * scale) / 2
    return { x: x + (clientX - rect.left - offX) / scale, y: y + (clientY - rect.top - offY) / scale }
  }

  // Zoom about a point, so the feature under the pointer stays under it. The clamp is applied to
  // the WIDTH and the height follows it, which is what keeps the aspect ratio through a zoom that
  // hits either bound.
  function zoomAbout(px, py, factor) {
    const [ x, y, w, h ] = view
    const nextW = Math.min(Math.max(w * factor, span() / 500), span() * 4)
    const nextH = h * (nextW / w)
    setViewBox([ px - (px - x) * (nextW / w), py - (py - y) * (nextH / h), nextW, nextH ])
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
      const [ a, b ] = [ ...pointers.values() ]
      pinchStart = { dist: Math.hypot(a.x - b.x, a.y - b.y), view: [ ...view ],
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
      const [ a, b ] = [ ...pointers.values() ]
      const dist = Math.hypot(a.x - b.x, a.y - b.y)
      // EVERY PINCH FRAME IS MEASURED FROM THE VIEW AT TOUCH-DOWN, never from the previous frame:
      // compounding per-frame factors accumulates the rounding of every move the gesture made, so
      // pinching out and back in again does not return to where it started.
      if (dist > 0) {
        view = [ ...pinchStart.view ]
        zoomAbout(pinchStart.centre.x, pinchStart.centre.y, pinchStart.dist / dist)
      }
      return
    }
    if (!panOrigin) return
    if (Math.hypot(event.clientX - panScreen.x, event.clientY - panScreen.y) > PAN_SLOP_PX) didPan = true
    const p = toUserSpace(event.clientX, event.clientY)
    const [ x, y, w, h ] = view
    setViewBox([ x + (panOrigin.x - p.x), y + (panOrigin.y - p.y), w, h ])
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
    view: () => [ ...view ],
    set: (next) => setViewBox(next),
    // `didPan` is "the gesture that just ended moved far enough to be a pan", read by a click
    // handler that must not treat a drag as a selection. It is cleared by the NEXT pointerdown, so
    // a reader never has to clear it and two readers of one gesture agree.
    didPan: () => didPan,
    // Live state, unlike `didPan`: true from the first pointerdown of a gesture, before the slop is
    // crossed. Measure's hover asks this so a drag does not repaint a hover highlight per move.
    panning: () => panOrigin !== null || pinchStart !== null,
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
