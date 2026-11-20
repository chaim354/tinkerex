# An HTML file's thumbnail is a drawing, not its source

**Date:** 2026-11-20 · **Follows:** the sandboxed HTML viewer (PR #544, `2026-11-19-embedded-files-design.md`)

## The problem

An `.html` file is in the `code` role, so `Maker::Previews::Registry` hands it to `TextThumb`, and
its Library tile is the first sixteen lines of its source: `<meta charset="utf-8">`, a `<title>`, the
start of a stylesheet. For a page like `Projects/pc case/out/viewer/walnut-pc-case.html` — a 3D
viewer that renders a walnut PC case — that tile says nothing about what the file is.

## The decision

The owner chose **a fixed drawing, the same for every HTML file**: "just do a logo or something
cute". Of three mockups (a `</>` code mark, a happy face, a walnut cube) they picked **the code
mark**: an ink browser window with three coloured dots in its title bar and an orange `</>` in the
middle.

Rejected, with the reason:

- **Link a photo** (`photo_of`, "Add a photo of this"): needs a click per file, and the tile
  machinery would have to resolve one node's thumbnail through another node — a renderer is handed
  one file's bytes and nothing else.
- **A real screenshot** (headless Chromium): hundreds of MB in the image or a new sidecar, WebGL
  in software, internet access for pages that load from a CDN, and the owner's HTML running on the
  server. Far too much for a tile.

## Design

### The renderer

`Maker::Previews::HtmlThumb` (`app/services/maker/previews/html_thumb.rb`), the published renderer
contract (`EXTENSIONS`, `available?`, `render(bytes, size:)`):

- `EXTENSIONS = Maker::FileAttachment::HTML_EXTS` — derived from the vocabulary, never listed
  (`["html"]`; `.htm` has no role and is not covered, as in the viewer).
- `render` **ignores the bytes** and returns the drawing as a `size`×`size` PNG through
  `Maker::Previews::SvgRasterizer.to_png`, the resvg step `TextThumb` already uses. No new binary.
- `available? = SvgRasterizer.available?`, exactly like `TextThumb`.
- `THUMBNAIL_REVISION = 3` and `payload_revision(_kind)`, `TextThumb`'s shape.

**The drawing**, on a 512 grid scaled to `size`:

- a pure-white ground, `Palette::PAPER` (design-system.md rule 5: the card's colour comes through
  by multiply, so anything off white shows as a tinted square);
- a rounded browser window outlined in `Palette::INK`, with a title-bar rule beneath three dots;
- the dots, left to right: `Palette::ACCENT`, then amber `#e0a526`, then sage `#6b8f5e` — the
  last two are `HtmlThumb` constants, decoration of this one drawing, not palette colours;
- `</>` centred in the window in `Palette::ACCENT`, drawn as two chevrons and a slash in
  round-capped strokes — never a `<text>`, whose glyph would be whatever face the box resolves.

It is rasterised with **`stylesheet: nil`**, `Gerber`'s opt-out: the rasterizer's default stylesheet
pins every stroke to 1.5px for hairline CAD sources, and through it the window came out a hairline
(found by rendering the first build and looking at it).

The mockup is the reference picture: `tmp/html-thumb-mockups.png`, option 1 (not committed).

> **Amended 2026-11-20, after deploy: the revision is 4, not 3.** This section counted only the
> revisions `TextThumb` declares in main's history (1 and 2). The Shop manual redesign (0edba844)
> had taken it to 3, been deployed, and been reverted (7b04b903), so HTML rows stamped 3 existed;
> on share one of them read as current under `HtmlThumb` 3 and kept its source picture. A deployed
> number is spent even when reverted (measure-view.md).

### Why revision 3, not 1

A stored thumbnail is current only when its `renderer_revision` **equals** the revision of the
renderer its filename resolves to (`Enqueue.revision_current?`). Every HTML tile in a library today
was drawn by `TextThumb` and is stamped **2**. Starting `HtmlThumb` at 2 would make every one of
them current, and the source-text picture would be served forever (§14h); starting at 1 would do
the same for any row left at `TextThumb`'s revision 1. At **3** every existing HTML row is stale,
so `ThumbnailMap`'s backfill redraws it the next time a page shows it, and
`rake previews:backfill_missing` redraws the rest — no migration.

### The registry

- `"html" => Maker::Previews::HtmlThumb` joins `Registry::FORMAT_RENDERERS`, which is merged over
  the derived text table, so `.html` resolves to `HtmlThumb`.
- `TextThumb::EXTENSIONS` becomes `TEXT_EXTENSIONS - HtmlThumb::EXTENSIONS`. Without that,
  `renderer_contract_test.rb` goes red — every renderer's `EXTENSIONS` must resolve back to it —
  which is the guard working as its comment says it should.

### The palette

`Palette::ACCENT = "#c2410c"`, Paper's `--accent` in `application.css`. `palette_test.rb` already
holds `INK` equal to Paper's `--fg`; it gains the same pin for `ACCENT`, so the drawing's orange
cannot drift from the app's. The palette's "changing a value here is a re-render" list names
`HtmlThumb` beside `TextThumb`.

### What does not change

The file page (Rendered / Source), the File block, the sandbox door, and `.htm`. Only the
thumbnail — every surface that shows one: the Library grid, list and inspector, search, the
project page's file rows, public pages.

## Tests

- **`html_thumb_test.rb` (new):** two different HTML documents render byte-identical PNGs of the
  requested size; the SVG draws its mark in strokes with no `<text>`; `render` differs from the
  same SVG rasterised through the hairline stylesheet.
- **`palette_test.rb`:** the SVG paints exactly `PAPER`, `INK`, `ACCENT` and the two dot colours.
- **`registry_test.rb`:** `for_filename("a.html")` is `HtmlThumb`, and `TextThumb::EXTENSIONS`
  does not include `html`.
- **`thumbnail_revision_test.rb`:** `"a.html" => 3` in the absolute table.
- **`palette_test.rb`:** `ACCENT` is Paper's `--accent`, and joins the lowercase-hex check.
- **`thumbnail_map_test.rb`:** an HTML node holding a `ready` row at revision 2 is not current and
  is re-enqueued by a page render.
- **Mutation checks:** `THUMBNAIL_REVISION` set to 2 must turn the staleness and revision tests
  red; `TextThumb` still claiming `html` must turn the contract test red.
- **`bin/ci`** green, the three backend legs at equal RUN counts.

## Docs

One rule in `docs/invariants/files-preview.md`'s HTML section: an HTML file's tile is a fixed
drawing and its renderer ignores the bytes; `HtmlThumb::THUMBNAIL_REVISION` must never be 1 or 2,
the revisions `TextThumb` stamped on HTML rows before this change, or those rows read as current
and keep their source-text picture.

## After deploy

Run `rake previews:backfill_missing` on share so every HTML tile redraws at once rather than as
pages are opened. Record the deploy with `bin/log deploy`.
