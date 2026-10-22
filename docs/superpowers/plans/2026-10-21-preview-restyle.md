# Preview restyle — every preview surface on the design system — Implementation Plan

> **For agentic workers:** execute with `.claude/commands/execute-plan.md` (the house default):
> batched by file, parallel where independent, one capped quality review per task.

**Goal:** every preview surface — the interactive viewers in the browser and the thumbnails the
server bakes — uses the design system's tokens and reads in both themes; existing thumbnails are
re-rendered through the renderers' own revision mechanism.

**Owner's words (2026-10-21):** "we worked on the design of the app but the colors and design of
all the different previews are not consistent with that". Asked how far to go: viewers AND
server-rendered thumbnails follow the design system and light/dark where possible, AND existing
thumbnails are re-rendered.

**Worktree:** `.claude/worktrees/preview-restyle-7f73e2`, branch `claude/preview-restyle-7f73e2`.
**SYNC_PORT** 3074. Dev server for screenshots on 3284.

---

## 1. Inventory (measured 2026-10-21 on this branch's base, `faa3045f`)

### Interactive viewers

| Surface | Code | Ground | Ink / material | Theme behaviour today |
|---|---|---|---|---|
| 3D viewer (o3dv) | `modelviewer_controller.js`, `bin/build-o3dv` | `.model-viewer-stage` `--raised`, read by `getComputedStyle` at construct | `defaultColor` literal `rgb(150,160,170)` (cool blue-grey); edges off (black literal) | ground follows the theme at open; a switch while open keeps the old ground |
| Gerber viewer (tracespace) | `gerber_controller.js` | `--raised` | layer `currentColor` = `--fg`; a board is tracespace's own board colours | follows the theme, live (CSS) |
| Measure view | `measure_controller.js`, `lib/shape_svg.js` | **none** — transparent onto the page | the file's layer colours (presentation attribute), `#000000` fallback; hover `#2b7`, selection `#d40` | **broken in Graphite**: a black layer (LightBurn C00, DXF ACI 7, most SVGs) is black on `#141512` |
| Print sheet / SVG export | `lib/print_sheet.js`, `lib/export_svg.js` | white paper | black / layer colour | print-correct; **not touched** |
| Code viewer, editor, diff, history, README editor | `lib/codemirror_theme.js`, vendored bundle, `vendor-overrides.css` | light: tokens (CSS); dark: **oneDark** `#282c34` | light: CM default highlight (`#708` keywords…); dark: oneDark's palette | light is ours, dark is a cool blue-grey theme from another product; chosen at mount, a switch keeps it |
| KiCanvas | `kicanvas_controller.js`, vendored | KiCanvas theme | KiCanvas theme | always **Witch Hazel** (dark purple), in both themes |
| PDF frame | `files/viewers/_pdf` | the browser's viewer | — | n/a (border token already) |
| Image frame, static thumbnail frame, poster | `_image`, `_static`, the fallbacks | `.preview` panel (page ground) | the PNG | a white PNG is a white square on Graphite |
| README (rendered) | server markdown in `.prose` | tokens | tokens | follows (already right) |

### Server-rendered thumbnails

| Renderer | Ground | Ink / material | Revision |
|---|---|---|---|
| `Stl` (`tools/stl-thumbnailer`, Rust) | **`#202228`** (dark, cool) | `0.78,0.80,0.84` (cool light grey) | 2 |
| `ThreeMf` mesh fallback (calls `Stl`) | same | same | 2 (lockstep) |
| `ThreeMf` embedded slicer thumbnail | the slicer's own | — | (same row) |
| `Mesh` (F3D: obj/step/stp/iges/igs) | **`#333333`** F3D default, **plus F3D's grid, axis gizmo and a filename banner naming the job's TEMPFILE path** (packaged config) | the file's own colours, else F3D default | 1 (BASE, undeclared) |
| `TextThumb` | white | `#1c2230` (cool) | 1 (BASE, undeclared) |
| `Svg` / `Dxf` / `Lbrn2` outline (resvg `--background white`) | white | the file's own colours, black fallback | 1 / 3 / 4 |
| `Lbrn2` / `Mage` embedded thumbnail (the file's own PNG) | **white, opaque** — measured on all 22 of 22 real catan files | LightBurn's | — |
| `Gerber` / `GerberZip` (tracespace under node + resvg) | white | layer: black `currentColor`; board: tracespace's | 1 |
| `Pdf` (page 1), `ImageThumb` | the file's own pixels | — | 1 |
| Tile stage `--thumb-stage` | `#ffffff` in **both** themes (rule 5) | `--thumb-ink #5b5c55` | — |

**What the owner sees:** in Paper, an STL or STEP tile is a dark square among white ones (and a
STEP carries a grid and a tempfile path); in Graphite every tile is a glaring white square.

## 2. Decisions made without the owner

1. **ONE THUMBNAIL TREATMENT: INK ON PAPER, AND THE CARD TAKES ITS COLOUR FROM THE THEME BY
   `mix-blend-mode: multiply`.** Every render keeps (or now paints) a pure-white ground; the stage
   (`--thumb-stage`) is a light card in both themes — Paper's surface `#fcfbf8` in light, a dimmed
   paper `#bfbbb2` in Graphite — and a render is multiplied onto it, so white becomes the card and
   ink stays ink. **Why not transparent renders on a theme-dark stage:** half this library is line
   art in the FILE'S colours (LightBurn's black and blue layers, DXF ACI 7, user SVGs), which reads
   on no dark ground — measured: LightBurn blue `#0000ff` is 1.96:1 on Graphite — and ~90% of
   LightBurn/MillMage files carry their OWN thumbnail on opaque white (22 of 22 real catan files),
   which no renderer of ours can make transparent without editing the file's pixels. Multiply is the
   one mechanism that gives every tile kind — our renders, LightBurn's, a PDF page, a slicer's —
   the same ground in both themes without touching a stored pixel. **Measured on `#bfbbb2`:** card
   9.6:1 against Graphite's page (it no longer out-shines the text, ~19:1 before); black ink 11:1;
   LightBurn blue 6.7:1, red 3.4:1 (3.95:1 on Paper); `--thumb-ink` flips to `#3d3e38` there (5.6:1;
   the Paper `#5b5c55` is 6.5:1 on `#fcfbf8`). Photos (`.thumb.photo`) opt out: they are not renders.
2. **ONE MESH MATERIAL, `#7f7b73`, FOR THE THUMBNAILERS AND THE 3D VIEWER.** Chosen so the
   silhouette clears 3:1 on all four grounds it meets: the viewer's `--raised` in Paper (3.44:1) and
   Graphite (3.61:1), and the card in Paper (4.18:1) and Graphite (3.58:1). One colour that reads on
   both viewer grounds is what lets a live theme switch repaint only the viewer's background.
3. **F3D LOSES ITS GRID, AXES AND FILENAME BANNER** (explicit `--grid=false --axis=false
   --filename=false --metadata=false`), keeps its packaged camera (the Z-up iso view) and honours a
   file's own colours; `--color` applies only where the file names none. `--no-config` was tried
   and rejected: it also drops the Z-up camera and shows a STEP from above.
4. **VIEWERS FOLLOW THE THEME, AND A SWITCH REPAINTS AN OPEN VIEWER** wherever the colour is CSS
   (Gerber, Measure chrome, CodeMirror now, the frames) and the 3D viewer's background through a
   theme observer. **KiCanvas changes on the NEXT page**: its theme is a module-load preference
   (`kc:prefs:theme` in localStorage, read once at import), so the controller writes `kicad` under
   Paper and `witchhazel` under Graphite before importing, and an open embed keeps the theme it
   loaded with.
5. **THE MEASURE STAGE IS THE CARD IN BOTH THEMES**, for the same reason as decision 1: it draws
   the file's own layer colours. Its chrome follows the theme. Hover/selection literals unchanged
   (pinned by computed style; both read on the card). Print sheet and SVG export untouched.
6. **CODEMIRROR IS TOKEN-DRIVEN IN BOTH THEMES; oneDark GOES.** Chrome in `vendor-overrides.css`
   for both themes, syntax through a `HighlightStyle` of `--code-*` custom properties (added to the
   ONE vendored bundle's exports; no new pin). Being CSS variables, a theme switch repaints an open
   editor with no remount. Every `--code-*` token clears 4.5:1 on `--surface` in its theme
   (comments the lowest, 5.13:1 in both).
7. **"Use this view as preview" captures on the render paper (white)**, never the theme's viewer
   ground, so a picture saved in Graphite multiplies onto the card like every other render.
8. **RE-RENDER = REVISION BUMPS, NOTHING ELSE:** `Stl` 2→3, `ThreeMf` 2→3 (lockstep, §14h),
   `Mesh` 1→2 and `TextThumb` 1→2 (both declare a revision for the first time). Outline renderers,
   Gerber, PDF, images: no output change, no bump. **No new sweep job, no migration.**
9. **SCREENSHOTS** live on an orphan branch `pr-assets/preview-restyle` (never merged), so a dozen
   PNGs do not enter `main`'s history; the PR links them by commit SHA.

## 3. What happens on the next deploy (for the PR)

Counted read-only on the live share box (2 users, each a full copy of one library):
STL 279 ready + 10 unsupported (1 viewer-chosen row is left alone), 3MF 104, F3D mesh 42 ready +
44 unsupported, text 3,286 → **~3,765 rows**, ~1,880 per library copy. Nothing re-renders at boot.
A row is re-rendered when a page that shows it renders (`ThumbnailMap`'s backfill, capped per
render) or when the operator runs `bin/rails previews:backfill_missing` (`DRY_RUN=1` first prints
the count). Throttling is the queue's: one Solid Queue process, 3 threads, a render is ~70–90 ms
(STL/text) to a few seconds (F3D) — the whole backlog is minutes. **Tiles keep the old picture**
while a row is `rebuilding` (§14h) and swap when the job lands; an `unsupported` row goes
`pending` (a spinner) and back to its badge. The CI runner image bakes `stl-thumbnailer` at image
build time, so CI keeps rendering with the old binary until that image is rebuilt; the production
image builds the crate from the repo, so the binary and the revision bump ship together.

## 4. Tasks

| Task | Owner | Files |
|---|---|---|
| T0 tokens | parent | `application.css` (`--thumb-stage`/`--thumb-ink` per theme, `--model-material`, `--code-*`) |
| T1 server renderers | subagent | `tools/stl-thumbnailer/src/lib.rs` + its tests, `app/services/maker/previews/{palette,stl,three_mf,mesh,text_thumb,svg_rasterizer}.rb`, their tests, `thumbnail_revision_test.rb`, a palette guard test, `measure-view.md` / `files-preview.md` lines that name these revisions |
| T2 CodeMirror | subagent | `vendor/javascript/codemirror-entry.js`, `codemirror.js` (rebuilt), `lib/codemirror_theme.js`, the five mounts' comments, `vendor-overrides.css`, `test/system/code_theme_test.rb` |
| T3 stages + viewers | parent | `components.css`, `pages/{preview,files,projects,models,landing,tools,public}.css`, `modelviewer_controller.js`, `kicanvas_controller.js`, design-system.md rules 2 and 5, css guard |
| T4 verify | parent | screenshots before/after × both themes, bare `bin/ci`, PR, record |

T1 and T2 touch disjoint paths from each other and from T3 (T2 alone owns `vendor-overrides.css`).
