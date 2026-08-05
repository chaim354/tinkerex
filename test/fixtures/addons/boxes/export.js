import { buildModel, printPrims } from "./plan.js"
import { paginate, PAPERS } from "./sheet.js"
import { buildPdf } from "./pdf.js"

// The renderers and the four sinks: print, PDF, SVG, and the library file editor.js saves.
//
// EVERYTHING HERE IS IN MILLIMETRES. One SVG user unit is one millimetre and the root carries
// width/height in mm, so the drawing has a physical SIZE rather than merely a shape. A viewBox
// alone is what the on-screen panel already had — and a viewBox alone is exactly what is not to
// scale.
//
// All four sinks render the SAME model through the same two functions below, so what you print,
// download and save cannot disagree with the panel you are looking at.

const STROKE = {
  opening: 0.25, outline: 0.5, mark: 0.25, "calib-bar": 0.4, "calib-tick": 0.3,
}

export function pageSvg({ paper, prims }) {
  return svgDoc(paper.w, paper.h, prims)
}

export function planSvg({ w, h, prims }) {
  return svgDoc(w, h, prims)
}

// Re-exported so a caller (and the tests) can build a model without also importing plan.js.
export const buildModelFor = buildModel

// The whole plan, full size, untiled — what goes to the library.
export function planSvgFor(model) {
  return planSvg({ w: model.w, h: model.h, prims: printPrims(model) })
}

export function pagesFor(model, paperName) {
  return paginate({ w: model.w, h: model.h, prims: printPrims(model) }, PAPERS[paperName])
}

function svgDoc(w, h, prims) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${n(w)}mm" height="${n(h)}mm" ` +
         `viewBox="0 0 ${n(w)} ${n(h)}">` +
         `<g fill="none" stroke="#000" stroke-linecap="square">${prims.map(prim).join("")}</g>` +
         `</svg>`
}

function prim(p) {
  if (p.kind === "line") {
    return `<line x1="${n(p.x1)}" y1="${n(p.y1)}" x2="${n(p.x2)}" y2="${n(p.y2)}" ` +
           `stroke-width="${STROKE[p.role] ?? 0.25}"/>`
  }
  return `<text x="${n(p.x)}" y="${n(p.y)}" font-family="Helvetica, Arial, sans-serif" ` +
         `font-size="${n(p.size)}" text-anchor="${p.anchor ?? "middle"}" ` +
         `dominant-baseline="middle" fill="#000" stroke="none">${esc(p.text)}</text>`
}

const n = (v) => (Math.round(v * 100) / 100).toString()
const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]))

// ---- the sinks --------------------------------------------------------------------------------

const PRINT_FRAME_CLASS = "plan-print-frame"

// A hidden iframe, deliberately, and not either alternative: window.open can be eaten by a popup
// blocker, and a print-only container in the host page would mean injecting a <style> that hides
// chrome this bundle does not own.
export function printPlan(model, paperName) {
  const { pages } = pagesFor(model, paperName)
  const paper = PAPERS[paperName]

  document.querySelector(`.${PRINT_FRAME_CLASS}`)?.remove()
  const frame = document.createElement("iframe")
  frame.className = PRINT_FRAME_CLASS
  frame.setAttribute("aria-hidden", "true")
  frame.style.cssText = "position:fixed;right:0;bottom:0;width:1px;height:1px;opacity:0;border:0"
  document.body.appendChild(frame)

  const doc = frame.contentDocument
  doc.open()
  doc.write(
    `<!doctype html><html><head><meta charset="utf-8"><title>Tray plan</title><style>` +
    `@page { size: ${paper.w}mm ${paper.h}mm; margin: 0 }` +
    `html,body { margin:0; padding:0; background:#fff }` +
    `svg { display:block; page-break-after:always; break-after:page }` +
    `svg:last-child { page-break-after:auto; break-after:auto }` +
    `</style></head><body>${pages.map(pageSvg).join("")}</body></html>`)
  doc.close()

  // The document has to settle before print(), or an empty frame goes to the spooler.
  const go = () => { frame.contentWindow.focus(); frame.contentWindow.print() }
  if (doc.readyState === "complete") go()
  else frame.addEventListener("load", go, { once: true })
  return pages.length
}

export function downloadSvg(model, paperName, base) {
  const { pages } = pagesFor(model, paperName)
  // One page -> that page. Several -> the untiled plan, because a browser download is one file and
  // a pile of separate page SVGs is less useful than the whole drawing. Print is the tiled sink.
  const svg = pages.length === 1 ? pageSvg(pages[0]) : planSvgFor(model)
  save(new Blob([ svg ], { type: "image/svg+xml" }), `${base}-plan.svg`)
  return pages.length
}

export function downloadPdf(model, paperName, base) {
  const { pages } = pagesFor(model, paperName)
  save(new Blob([ buildPdf(pages) ], { type: "application/pdf" }), `${base}-plan.pdf`)
  return pages.length
}

function save(blob, name) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
