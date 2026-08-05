// A minimal PDF 1.4 writer, for a drawing that is only axis-aligned lines and short text. No
// compression, no font embedding (Helvetica is one of the base-14 fonts every viewer has), no
// dependency — which is why this is ~120 lines rather than a vendored library, and why §9's
// licence constraint never comes up.
//
// WHY A PDF AT ALL, given print already exists: the browser's print dialog defaults to "Fit to
// printable area" and rescales silently, which no page can detect or prevent. A PDF carries its
// physical size in the file, so it is the one sink that is exact by construction.
//
// THE Y-AXIS FLIPS. SVG's y grows downward from the top-left; PDF's grows upward from the
// bottom-left. Every coordinate is transformed on the way in. This is the most dangerous line in
// the module, because a flipped plan is INVISIBLE on a symmetric tray — the tests use an
// asymmetric one for exactly that reason.

const PT = 72 / 25.4 // millimetres -> points

const STROKE = {
  opening: 0.25, outline: 0.5, mark: 0.25, "calib-bar": 0.4, "calib-tick": 0.3,
}

// The few non-ASCII characters this drawing emits, as WinAnsiEncoding octal escapes. Octal escapes
// are themselves ASCII, so the whole file stays 7-bit — which is what would let a PDF go through
// the addon save endpoint's JSON `files` contract if that is ever wanted (see the spec's §7).
const WINANSI = {
  0x00d7: "\\327", // × multiplication sign, in every compartment label
  0x2014: "\\227", // — em dash, in the calibration caption
  0x2013: "\\226", // – en dash
  0x00b7: "\\267", // · middle dot
}

export function buildPdf(pages) {
  const objects = []
  const add = (body) => { objects.push(body); return objects.length }

  const fontId = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " +
                     "/Encoding /WinAnsiEncoding >>")

  // A /Page's /Parent must name the Pages object, which cannot be written until its /Kids are
  // known — so the id is predicted here and ASSERTED below. Predicting ids and offsets is exactly
  // how a hand-rolled writer goes silently wrong; an assertion turns that into a loud failure at
  // build time instead of a subtly broken file.
  const pagesId = objects.length + pages.length * 2 + 1
  const kids = []

  for (const page of pages) {
    const content = contentStream(page)
    const streamId = add(`<< /Length ${content.length} >>\nstream\n${content}\nendstream`)
    kids.push(add(
      `<< /Type /Page /Parent ${pagesId} 0 R ` +
      `/MediaBox [0 0 ${pt(page.paper.w)} ${pt(page.paper.h)}] ` +
      `/Resources << /Font << /F1 ${fontId} 0 R >> >> /Contents ${streamId} 0 R >>`))
  }

  const realPagesId = add(
    `<< /Type /Pages /Count ${kids.length} /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] >>`)
  if (realPagesId !== pagesId) {
    throw new Error(`pdf: /Parent mispredicted (${pagesId} vs ${realPagesId})`)
  }
  const catalogId = add(`<< /Type /Catalog /Pages ${realPagesId} 0 R >>`)

  return assemble(objects, catalogId)
}

function contentStream({ paper, prims }) {
  const H = paper.h
  const out = []
  let width = null

  for (const p of prims) {
    if (p.kind === "line") {
      const w = STROKE[p.role] ?? 0.25
      if (w !== width) { out.push(`${num(w * PT)} w`); width = w }
      out.push(`${pt(p.x1)} ${pt(H - p.y1)} m ${pt(p.x2)} ${pt(H - p.y2)} l S`)
    } else {
      const size = p.size * PT
      // PDF has no text-anchor, so shift by an estimate of the rendered width. Helvetica's average
      // advance is roughly 0.5 em, which is close enough for a label that was already measured
      // against the compartment it sits in (plan.js drops one that would not fit).
      const est = p.text.length * size * 0.5
      const dx = p.anchor === "end" ? -est : p.anchor === "start" ? 0 : -est / 2
      out.push(`BT /F1 ${num(size)} Tf ` +
               `${num(p.x * PT + dx)} ${num((H - p.y) * PT - size * 0.35)} Td ` +
               `(${escapeText(p.text)}) Tj ET`)
    }
  }
  return out.join("\n")
}

function escapeText(s) {
  return String(s)
    .replace(/[\\()]/g, (c) => `\\${c}`)
    .replace(/[^\x20-\x7e]/g, (c) => WINANSI[c.charCodeAt(0)] ?? "?")
}

function assemble(objects, catalogId) {
  let out = "%PDF-1.4\n"
  const offsets = []
  objects.forEach((body, i) => {
    offsets.push(out.length)
    out += `${i + 1} 0 obj\n${body}\nendobj\n`
  })

  // Offsets are recorded as each object is APPENDED, never predicted from lengths.
  const xref = out.length
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`
  for (const off of offsets) out += `${String(off).padStart(10, "0")} 00000 n \n`
  out += `trailer\n<< /Size ${objects.length + 1} /Root ${catalogId} 0 R >>\n` +
         `startxref\n${xref}\n%%EOF\n`

  const bytes = new Uint8Array(out.length)
  for (let i = 0; i < out.length; i++) bytes[i] = out.charCodeAt(i) & 0xff
  return bytes
}

const num = (v) => (Math.round(v * 100) / 100).toString()
const pt = (mm) => num(mm * PT)
