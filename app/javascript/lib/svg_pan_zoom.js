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

  // A viewBox WITH A NaN IN IT IS A BLANK STAGE, AND IT STAYS BLANK: every later pan and zoom is
  // arithmetic on the poisoned value. So a next view that is not finite in every component is
  // refused and the current one kept — Fit still works, because `home` is finite.
  function setViewBox(next) {
    if (!next.every(Number.isFinite)) return
    const [ x, y, w, h ] = next
    view = [ x, y, w, h ]
    svg.setAttribute("viewBox", `${x} ${y} ${w} ${h}`)
    onChange?.(view)
  }

  // Screen px -> user units (see the header for why the letterbox is part of this).
  //
  // AN ELEMENT WITH NO SIZE HAS NO SCALE, and dividing by it is how a NaN got into the viewBox:
  // measured in a hidden browser pane (viewport 0 x 0, every rect 0 x 0), where one wheel event
  // left `NaN NaN 308.7 56.5` on the real Wheel Clock board until Fit was pressed. A collapsed
  // container, a display:none ancestor mid-transition or a background tab is the same shape. The
  // honest answer for a point on a sizeless element is the view's own centre.
  function toUserSpace(clientX, clientY) {
    const rect = svg.getBoundingClientRect()
    const [ x, y, w, h ] = view
    if (!(rect.width > 0 && rect.height > 0)) return { x: x + w / 2, y: y + h / 2 }
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

  // THE GESTURE IS DECIDED BY HOW MANY POINTERS ARE DOWN, RE-DERIVED ON EVERY DOWN AND UP: one is
  // a pan from that pointer's current position, exactly two is a pinch measured from the view at
  // the moment the pair formed, anything else is nothing. Re-deriving (rather than arming state on
  // the transitions the author imagined) is what keeps a third finger, or one of three lifting,
  // from leaving a stale pinch or a pan origin from before a zoom — the review measured both as a
  // view that jumped twice on a single pixel of movement.
  function rearm() {
    const active = [ ...pointers.values() ]
    if (active.length === 2) {
      const [ a, b ] = active
      pinchStart = { dist: Math.hypot(a.x - b.x, a.y - b.y), view: [ ...view ],
                     centre: toUserSpace((a.x + b.x) / 2, (a.y + b.y) / 2) }
      panOrigin = null
      // A pinch is a gesture, not a click: whatever pointerup follows it must not select.
      didPan = true
      return
    }
    pinchStart = null
    if (active.length === 1) {
      const [ p ] = active
      panOrigin = toUserSpace(p.x, p.y)
      panScreen = { x: p.x, y: p.y }
      return
    }
    panOrigin = null
  }

  function onPointerDown(event) {
    if (event.button !== 0 && event.pointerType === "mouse") return
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY })
    svg.setPointerCapture(event.pointerId)
    if (pointers.size === 1) didPan = false
    rearm()
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
    if (!pointers.has(event.pointerId)) return
    pointers.delete(event.pointerId)
    svg.releasePointerCapture?.(event.pointerId)
    rearm()
    if (pointers.size === 0) svg.classList.remove("is-panning")
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
