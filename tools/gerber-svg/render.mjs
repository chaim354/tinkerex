// tracespace under node: one Gerber/Excellon layer, or one board, to SVG on stdout.
//
// THE SAME PINNED BUNDLE THE BROWSER RUNS (bin/build-tracespace builds both from one node_modules),
// so a thumbnail is the viewer's own picture — never a second parser. Exec'd by
// Maker::Previews::Gerber / GerberZip the way resvg, pdfium and f3d are; nothing links it.
//
//   node render.mjs layer <file>           -> the one layer's SVG (renderLayers)
//   node render.mjs board <file> [<file>…] -> the board's TOP side (renderBoard)
//
// FILENAMES ARE LOAD-BEARING: tracespace identifies what a layer IS from the name (top copper,
// drill, outline…), never from the bytes — gerber_controller.js's header has the argument — so the
// caller writes each member under its real basename before invoking this.
//
// WHAT `renderLayers` EMITS FOR STROKE WIDTHS, measured 2026-09-07 against this bundle with
// GerberFixture::MINIMAL_GERBER (a 0.5 mm round aperture drawing a 10 mm square) — the whole
// output, not a paraphrase:
//
//     <svg … stroke-width="0" fill="currentColor" stroke="currentColor"
//            viewBox="-0.25 -10.25 10.5 10.5" width="10.5mm" height="10.5mm">
//       <path stroke-width="0.5" fill="none" d="M0 0L10 0L10 -10L0 -10L0 0"></path>
//     </svg>
//
// A REAL `stroke-width` IN THE LAYER'S OWN UNITS — the aperture's actual diameter. Not a hairline,
// and not an outlined polygon. That is why Maker::Previews::Gerber passes `stylesheet: nil` to
// SvgRasterizer: the shared STYLESHEET pins EVERY stroke to 1.5 device pixels for hairline CAD
// sources, which here would flatten a 0.5 mm signal trace and a 2 mm power trace to one width and
// throw away the one thing a board thumbnail is for. It is worse than a no-op on `board` mode,
// where the substrate, mask and drill layers are `<rect>`s inheriting `stroke="currentColor"` at
// `stroke-width="0"`: a 1.5 px rule paints a border around every one of them.
//
// A drill hit is a `<circle r="0.4">` with a fill and no stroke (measured on MINIMAL_DRILL) — the
// stylesheet could not reach it either way, which is exactly why a stroke-shaped assertion must be
// written against a `.gtl` and never a `.drl`.
//
// EXIT CODES ARE THE WIRE: 0 + SVG on stdout, 2 for a usage error, 3 when nothing parsed, 4 when
// there is nothing to draw. Anything else is node itself failing, which Gerber#run_node reports as
// a RenderError with stderr attached.
//
// 3 AND 4 ARE SEPARATE BECAUSE THE RUBY SIDE ANSWERS THEM DIFFERENTLY. A file that will not parse
// is a RenderError (the preview row goes `failed`); a file that parses to no geometry is
// GeneratePreviewJob::Unsupported (terminal, never retried). The second is an ORDINARY artefact —
// a board with no bottom silkscreen exports an empty `.gbo` — and measured against this bundle it
// renders `viewBox="0 0 0 0" width="0mm" height="0mm"`, which resvg then refuses outright with
// "SVG has no valid size". Left alone that is a `failed` row and an error badge on a file nothing
// is wrong with, re-rendered on every enqueue pass forever.
import { read, plot, renderLayers, renderBoard, stringifySvg } from "./tracespace.mjs"

const [mode, ...files] = process.argv.slice(2)
if (!["layer", "board"].includes(mode) || files.length === 0) {
  process.stderr.write("usage: render.mjs layer <file> | board <file> [<file>…]\n")
  process.exit(2)
}

const rendered = renderLayers(plot(await read(files)))
if (rendered.layers.length === 0) {
  process.stderr.write("no layer could be parsed\n")
  process.exit(3)
}
const svg = mode === "layer"
  ? stringifySvg(rendered.rendersById[rendered.layers[0].id])
  : stringifySvg(renderBoard(rendered).top)

// THE DEGENERATE RENDER, CAUGHT HERE RATHER THAN IN RUBY, because the viewBox is this script's own
// output and a Ruby-side string match on it would be a second place that has to know tracespace's
// markup. Both modes emit `viewBox="0 0 0 0"` when nothing plotted — measured on an empty layer and
// on a board composed of two empty layers.
const box = /viewBox="(-?[\d.]+) (-?[\d.]+) ([\d.]+) ([\d.]+)"/.exec(svg)
if (!box || Number(box[3]) <= 0 || Number(box[4]) <= 0) {
  process.stderr.write("nothing to draw\n")
  process.exit(4)
}
process.stdout.write(svg)
