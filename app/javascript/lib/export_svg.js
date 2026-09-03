// The Measure view's selected shapes -> one standalone SVG document, as a string.
//
// PURE. It builds a DETACHED document and serialises it: nothing here touches the page, starts a
// download, or knows what a Stimulus controller is. measure_controller.js owns that half — the
// same split print_sheet.js draws between renderSheet (pure) and buildPrintFrame (not).
//
// ONE USER UNIT IS ONE MILLIMETRE, and the width/height + viewBox pair is the ENTIRE scale
// mechanism. There is no transform and no dpi constant. Write the width in px, or let the viewBox
// span anything other than the selection's own millimetres, and the file looks identical while
// every part in it is the wrong size — in an application that will happily cut it. The print sheet
// and the boxes bundle's library SVG use the same mechanism for the same reason.
//
// NORMALIZED TO THE ORIGIN rather than keeping the file's coordinates: a part pulled out of a
// 1200 mm sheet otherwise imports as a speck in an empty canvas. The canvas size IS the part size,
// which is what makes the document tell you something.
import { SVG_NS, el, unionBox, shapeElement } from "lib/shape_svg"

// Hairline. Stroke width is ignored outright on CAD import and is a display choice everywhere
// else; 0.1 mm is thin enough not to obscure a small feature at 1:1. NOT print's 0.2 mm — that
// number is "a line you can cut to" on paper, which is not this file's job.
const STROKE_WIDTH = 0.1

// Match the payload's own PRECISION (Geometry::PRECISION = 2). The inputs are already rounded
// there; this keeps the width/height and the translate from picking up float dust when they are
// derived by subtraction.
const round = (v) => Math.round(v * 100) / 100

export function exportSvg(shapes, { colors = {} } = {}) {
  // REFUSES RATHER THAN WRITING AN EMPTY DOCUMENT. A 0 x 0 mm SVG opens in every viewer and shows
  // nothing, which reads as "the export is broken" rather than "you selected nothing" — and the
  // caller has a readout to put a message in. printSheets' own "Nothing to print." is the same
  // choice.
  if (!shapes || !shapes.length) throw new Error("Nothing selected to export.")

  const box = unionBox(shapes)
  // The root is created IN the SVG namespace, so XMLSerializer writes the xmlns declaration
  // itself. Do not also setAttribute("xmlns", ...) — that adds a second, null-namespace attribute
  // of the same name and the serialised document carries `xmlns` twice, which is not well-formed
  // XML and which some importers reject outright.
  const doc = document.implementation.createDocument(SVG_NS, "svg", null)
  const svg = doc.documentElement
  svg.setAttribute("width", `${round(box[2] - box[0])}mm`)
  svg.setAttribute("height", `${round(box[3] - box[1])}mm`)
  svg.setAttribute("viewBox", `0 0 ${round(box[2] - box[0])} ${round(box[3] - box[1])}`)

  // ONE TRANSLATE FOR THE WHOLE SET, not one per shape: several selected parts keep their relative
  // positions because they are all moved by the same amount. renderSheet puts its page translate
  // on one group for the identical reason.
  const group = el(doc, "g", { transform: `translate(${round(-box[0])} ${round(-box[1])})` })
  for (const shape of shapes) {
    const node = shapeElement(doc, shape)
    node.setAttribute("fill", "none")
    // THE LAYER COLOUR, sent by the server so the palette has one definition. Print chose black
    // because a mono printer turns a palette into indistinguishable greys; that argument does not
    // transfer to a file, and LightBurn maps stroke colour back to layers on import.
    node.setAttribute("stroke", colors[shape.c] || "#000000")
    node.setAttribute("stroke-width", STROKE_WIDTH)
    // A photo's base64 is deliberately absent from the payload, but the RECTANGLE it occupies is
    // real information. Selected means exported: a shape the user picked must not vanish silently.
    if (shape.i) node.setAttribute("stroke-dasharray", "4 3")
    group.appendChild(node)
  }
  svg.appendChild(group)

  return `<?xml version="1.0" encoding="UTF-8"?>\n${new XMLSerializer().serializeToString(doc)}`
}
