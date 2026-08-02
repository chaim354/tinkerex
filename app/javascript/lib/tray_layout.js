// The tray layout vocabulary, in ONE place: boxes.py's section syntax ("50*3"), the ASCII art it
// seeds a TrayLayout with, and the parse of that art back into walls and floors.
//
// It lives here rather than inside a controller because two of them need it — traylayout (which
// WRITES the art) and topview (which READS it) — and a second copy of a parser is this repo's
// recorded failure shape: `importer_controller.js`'s `roleFor` is a third copy of the extension
// vocabulary and has now drifted twice. One definition, imported twice, cannot disagree with itself.
//
// THE GRAMMAR, exactly as boxes.py's `TrayLayout.parse` reads it (traylayout.py):
//   " | ,> 50.0mm"  one header line per column, prefixed by one more " |" each time, giving its width
//   "+-+-+-+"       horizontal walls: at ODD offsets, "-" is a wall and " " is none
//   "| | | | 50mm"  cells: at EVEN offsets "|" is a wall; at ODD offsets " " is floor and "x"/"X" is
//                   none; the row's height is the trailing number
// A line's characters are POSITIONAL — column alignment is the data, which is why the field is a
// <textarea wrap="off"> and not an <input type="text"> (whose sanitization strips the newlines).

// Port of boxes.py's argparseSections: "50*3" -> three 50s, "100/4" -> four 25s, "30:40" -> 30, 40.
// Deliberately stricter than the Python original, which accepts anything float() does — returning
// null on anything unfamiliar (or half-typed) just means the caller leaves well alone, and the
// server still parses whatever the user actually typed.
export function sections(s) {
  const out = []
  for (const part of String(s ?? "").split(/[\s:]/)) {
    const repeat = part.match(/^(\d+(?:\.\d+)?)([*/])(\d+)$/)
    if (repeat) {
      const n = Number(repeat[3])
      if (!n || n > 100) return null // 100 compartments is already far past a usable tray
      out.push(...Array(n).fill(repeat[2] === "/" ? Number(repeat[1]) / n : Number(repeat[1])))
    } else if (/^\d+(?:\.\d+)?$/.test(part)) {
      out.push(Number(part))
    } else {
      return null
    }
  }
  return out.length && out.every((v) => v > 0) ? out : null
}

// Mirrors TrayLayoutFile.__str__ byte-for-byte (walls and floors all present), so what the browser
// writes is what the sidecar would have seeded.
export function buildArt(sx, sy) {
  if (!sx || !sy) return null
  let art = sx.map((v, i) => `${" |".repeat(i)} ,> ${v.toFixed(1)}mm\n`).join("")
  for (const v of sy) {
    art += `${"+-".repeat(sx.length)}+\n`
    art += `${"| ".repeat(sx.length)}| ${v.toFixed(1)}mm\n`
  }
  return `${art + "+-".repeat(sx.length)}+\n`
}

// Art -> {cols, rows, hwalls, vwalls}. Returns null rather than throwing on anything it cannot read:
// this runs on every keystroke in the textarea, so a half-typed layout is the NORMAL case and must
// simply leave the last good drawing up.
export function parseArt(text) {
  const cols = [], rows = [], hwalls = [], vwalls = []
  for (const line of String(text ?? "").split("\n")) {
    if (!line || line[0] === "#") continue
    const header = line.match(/^( \|)* ,>\s*(\d*\.?\d+)\s*mm/)
    if (header) { cols.push(parseFloat(header[2])); continue }
    if (!cols.length) continue
    const width = cols.length * 2 + 1
    if (line[0] === "+") {
      const w = []
      for (let i = 1; i < width; i += 2) w.push(line[i] === "-")
      hwalls.push(w)
    } else if (line[0] === " " || line[0] === "|") {
      const height = line.slice(width).match(/(\d*\.?\d+)\s*mm/)
      if (!height) return null
      const w = []
      for (let i = 0; i < width; i += 2) w.push(line[i] === "|")
      rows.push(parseFloat(height[1]))
      vwalls.push(w)
    }
  }
  // A "+" line above and below every row, or the art is mid-edit and the grid is not yet coherent.
  if (!cols.length || !rows.length || hwalls.length !== rows.length + 1) return null
  return { cols, rows, hwalls, vwalls }
}

// The grid a generator with sx/sy but NO layout describes: every wall present, all round the outside.
// (TypeTray, TrayInsert and the rest of that family — upstream calls it "only continuous walls".)
export function gridFrom(sx, sy) {
  if (!sx || !sy) return null
  return {
    cols: sx,
    rows: sy,
    hwalls: Array.from({ length: sy.length + 1 }, () => new Array(sx.length).fill(true)),
    vwalls: Array.from({ length: sy.length }, () => new Array(sx.length + 1).fill(true)),
  }
}

// Flood-fill the cells into compartments, crossing wherever a wall is ABSENT. This is what makes the
// view worth drawing: a layout's whole point is merging cells, and only the fill can say what the
// merge actually produced.
export function compartments({ cols, rows, hwalls, vwalls }) {
  const nc = cols.length, nr = rows.length
  const id = Array.from({ length: nr }, () => new Array(nc).fill(-1))
  const groups = []
  for (let r = 0; r < nr; r++) {
    for (let c = 0; c < nc; c++) {
      if (id[r][c] !== -1) continue
      const k = groups.length, cells = [], stack = [[ r, c ]]
      id[r][c] = k
      while (stack.length) {
        const [ a, b ] = stack.pop()
        cells.push([ a, b ])
        const reach = (p, q) => { if (id[p][q] === -1) { id[p][q] = k; stack.push([ p, q ]) } }
        if (b + 1 < nc && !vwalls[a][b + 1]) reach(a, b + 1)
        if (b > 0 && !vwalls[a][b]) reach(a, b - 1)
        if (a + 1 < nr && !hwalls[a + 1][b]) reach(a + 1, b)
        if (a > 0 && !hwalls[a][b]) reach(a - 1, b)
      }
      groups.push(cells)
    }
  }
  return { id, groups }
}
