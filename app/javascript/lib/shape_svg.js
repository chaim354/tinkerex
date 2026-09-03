// One geometry-payload shape -> one SVG element. THE ONE DEFINITION, shared by the Measure view,
// the print sheet and the SVG export.
//
// GEOMETRY ONLY. This module picks the ELEMENT TYPE and writes the attributes that describe the
// outline. It never writes a colour, a class, a stroke width or a dash: its three callers want
// three different presentations of the same shape — a layer-coloured line under a transparent hit
// twin, a black 0.2 mm print line, a layer-coloured export line — and each applies its own. A
// third copy of the element-picking is exactly what this exists to prevent; §14d records that
// shape as five port_writable? branches and §14b as four skip-list strings.
//
// `shape.g` IS A DRAWING HINT, NEVER A MEASUREMENT. The server computes `b` and `d` from
// full-resolution points and sends `g` only where the FILE supplied an exact primitive — a
// LightBurn <Ellipse>, a DXF CIRCLE/ARC, an SVG <circle>/<ellipse> under an axis-aligned
// transform. NOTHING HERE INFERS ONE FROM THE POINTS, so a designed 16-gon stays a 16-gon even
// though the server's circularity test would call it round for the ⌀ label. A payload with no `g`
// on any shape draws exactly what this drew before `g` existed.
export const SVG_NS = "http://www.w3.org/2000/svg"

// THE ONE DOOR EVERY ELEMENT IN THIS FAMILY OF MODULES IS BUILT THROUGH. Moved here from
// print_sheet.js, which now imports and re-exports it — one door, and measure_print_test.rb's
// existing pin of the guard below keeps working through that re-export.
export function el(doc, tag, attrs, text) {
  // A STRING IN THE `attrs` SLOT DOES NOT THROW, WHICH IS THE WHOLE REASON THIS EXISTS.
  // `el(doc, "text", "Sheet 1,1 of 2×1")` — one dropped `{}` away from the five <text> sites in
  // print_sheet's `furniture` — was expected to raise InvalidCharacterError, since an attribute
  // name cannot begin with a digit. Probed in Chrome: it does not. `Object.entries` walks the
  // string's own indices and `setAttribute` accepts "0" as a name, so the result is
  // `<text 0="S" 1="h" 2="e" ...>` — sixteen junk attributes, no text content, an empty <text>
  // that renders nothing on a page that is otherwise perfectly formed, with nothing thrown and
  // nothing logged. Measured verbatim in measure_print_test.rb, which pins this.
  if (typeof attrs === "string") {
    throw new Error("el(doc, tag, attrs, text): the third argument is the attribute map, not " +
                    "the text — pass el(doc, tag, {}, text).")
  }
  const node = doc.createElementNS(SVG_NS, tag)
  for (const [ key, value ] of Object.entries(attrs)) {
    // An undefined value writes the literal string "undefined" (a null writes "null"). Sheet
    // furniture is full of conditional attributes, so skip here rather than making every call
    // site remember. print_sheet's `text()` is the live caller: it omits `text-anchor` entirely
    // for the default `start` rather than restating it. MEASURED, not reasoned, and carried here
    // with the function: an unguarded `text-anchor="undefined"` is an INVALID value, so
    // getComputedStyle reports `start` and the rendered bbox x comes back 99.99999237060547 —
    // byte-identical to the attribute being absent. The sheet looks EXACTLY right, which is why
    // measure_print_test.rb asserts the ATTRIBUTE rather than a position.
    if (value != null) node.setAttribute(key, value)
  }
  // THE TEXT DOOR EXISTS SO THAT `textContent` IS THE ONLY SPELLING. The print header carries a
  // library filename — user-controlled, and legitimately able to contain `<` on a NAS-scanned
  // share — so building it as markup is an injection into a same-origin iframe. Six call sites
  // each remembering that is six chances to forget; one door is none.
  if (text != null) node.textContent = text
  return node
}

// The bounding box of a set of shapes, from `b` — the server's FULL-RESOLUTION bbox, never the
// thinned drawing points. One definition for all three callers; it was written out twice (here
// and as measure_controller's `unionOf`) before the exporter needed a third.
export function unionBox(shapes) {
  return [
    Math.min(...shapes.map((s) => s.b[0])), Math.min(...shapes.map((s) => s.b[1])),
    Math.max(...shapes.map((s) => s.b[2])), Math.max(...shapes.map((s) => s.b[3])),
  ]
}

// A CIRCLE GETS <circle>, NOT AN <ellipse> WITH EQUAL RADII. Both are valid SVG and both draw the
// same picture, but the export's stated destinations are a vector editor and a CAD sketch import,
// where <circle> is the unambiguous primitive and an ellipse may arrive as a spline.
export function shapeElement(doc, shape) {
  const g = shape.g
  if (g && g[0] === "e") {
    const [ , cx, cy, rx, ry ] = g
    return rx === ry ? el(doc, "circle", { cx, cy, r: rx })
                     : el(doc, "ellipse", { cx, cy, rx, ry })
  }
  if (g && g[0] === "a") {
    const [ , x0, y0, x1, y1, r, large, sweep ] = g
    return el(doc, "path", { d: `M ${x0} ${y0} A ${r} ${r} 0 ${large} ${sweep} ${x1} ${y1}` })
  }
  // NO DESCRIPTOR -> THE THINNED POINTS, which is every path, polygon, polyline, rect and bitmap
  // and every curve the file did not describe as a primitive.
  return el(doc, shape.k ? "polygon" : "polyline",
            { points: shape.p.map(([ x, y ]) => `${x},${y}`).join(" ") })
}
